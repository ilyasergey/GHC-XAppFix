%
% (c) The University of Glasgow 2006
% (c) The AQUA Project, Glasgow University, 1996-1998
%

TcHsSyn: Specialisations of the @HsSyn@ syntax for the typechecker

This module is an extension of @HsSyn@ syntax, for use in the type
checker.

\begin{code}
{-# OPTIONS -fno-warn-tabs #-}
-- The above warning supression flag is a temporary kludge.
-- While working on this module you are encouraged to remove it and
-- detab the module (please do the detabbing in a separate patch). See
--     http://hackage.haskell.org/trac/ghc/wiki/Commentary/CodingStyle#TabsvsSpaces
-- for details

module TcHsSyn (
	mkHsConApp, mkHsDictLet, mkHsApp,
	hsLitType, hsLPatType, hsPatType, 
	mkHsAppTy, mkSimpleHsAlt,
	nlHsIntLit, 
	shortCutLit, hsOverLitName,
	
	-- re-exported from TcMonad
	TcId, TcIdSet, 

	zonkTopDecls, zonkTopExpr, zonkTopLExpr, mkZonkTcTyVar,
	zonkId, zonkTopBndrs
  ) where

#include "HsVersions.h"

-- friends:
import HsSyn	-- oodles of it

-- others:
import Id

import TcRnMonad
import PrelNames
import TcType
import TcMType
import TcEvidence
import TysPrim
import TysWiredIn
import Type
import Kind
import DataCon
import Name
import NameSet
import Var
import VarSet
import VarEnv
import DynFlags
import Literal
import BasicTypes
import Maybes
import SrcLoc
import Bag
import FastString
import Outputable
-- import Data.Traversable( traverse )
\end{code}

\begin{code}
-- XXX
thenM :: Monad a => a b -> (b -> a c) -> a c
thenM = (>>=)

returnM :: Monad m => a -> m a
returnM = return

mappM :: (Monad m) => (a -> m b) -> [a] -> m [b]
mappM = mapM
\end{code}


%************************************************************************
%*									*
\subsection[mkFailurePair]{Code for pattern-matching and other failures}
%*									*
%************************************************************************

Note: If @hsLPatType@ doesn't bear a strong resemblance to @exprType@,
then something is wrong.
\begin{code}
hsLPatType :: OutPat Id -> Type
hsLPatType (L _ pat) = hsPatType pat

hsPatType :: Pat Id -> Type
hsPatType (ParPat pat)                = hsLPatType pat
hsPatType (WildPat ty)                = ty
hsPatType (VarPat var)                = idType var
hsPatType (BangPat pat)               = hsLPatType pat
hsPatType (LazyPat pat)               = hsLPatType pat
hsPatType (LitPat lit)                = hsLitType lit
hsPatType (AsPat var _)               = idType (unLoc var)
hsPatType (ViewPat _ _ ty)            = ty
hsPatType (ListPat _ ty)              = mkListTy ty
hsPatType (PArrPat _ ty)              = mkPArrTy ty
hsPatType (TuplePat _ _ ty)           = ty
hsPatType (ConPatOut { pat_ty = ty }) = ty
hsPatType (SigPatOut _ ty)            = ty
hsPatType (NPat lit _ _)              = overLitType lit
hsPatType (NPlusKPat id _ _ _)        = idType (unLoc id)
hsPatType (CoPat _ _ ty)              = ty
hsPatType p                           = pprPanic "hsPatType" (ppr p)

hsLitType :: HsLit -> TcType
hsLitType (HsChar _)       = charTy
hsLitType (HsCharPrim _)   = charPrimTy
hsLitType (HsString _)     = stringTy
hsLitType (HsStringPrim _) = addrPrimTy
hsLitType (HsInt _)        = intTy
hsLitType (HsIntPrim _)    = intPrimTy
hsLitType (HsWordPrim _)   = wordPrimTy
hsLitType (HsInt64Prim _)  = int64PrimTy
hsLitType (HsWord64Prim _) = word64PrimTy
hsLitType (HsInteger _ ty) = ty
hsLitType (HsRat _ ty)     = ty
hsLitType (HsFloatPrim _)  = floatPrimTy
hsLitType (HsDoublePrim _) = doublePrimTy
\end{code}

Overloaded literals. Here mainly becuase it uses isIntTy etc

\begin{code}
shortCutLit :: OverLitVal -> TcType -> Maybe (HsExpr TcId)
shortCutLit (HsIntegral i) ty
  | isIntTy ty && inIntRange i   = Just (HsLit (HsInt i))
  | isWordTy ty && inWordRange i = Just (mkLit wordDataCon (HsWordPrim i))
  | isIntegerTy ty 	       	 = Just (HsLit (HsInteger i ty))
  | otherwise		       	 = shortCutLit (HsFractional (integralFractionalLit i)) ty
	-- The 'otherwise' case is important
	-- Consider (3 :: Float).  Syntactically it looks like an IntLit,
	-- so we'll call shortCutIntLit, but of course it's a float
	-- This can make a big difference for programs with a lot of
	-- literals, compiled without -O

shortCutLit (HsFractional f) ty
  | isFloatTy ty  = Just (mkLit floatDataCon  (HsFloatPrim f))
  | isDoubleTy ty = Just (mkLit doubleDataCon (HsDoublePrim f))
  | otherwise     = Nothing

shortCutLit (HsIsString s) ty
  | isStringTy ty = Just (HsLit (HsString s))
  | otherwise     = Nothing

mkLit :: DataCon -> HsLit -> HsExpr Id
mkLit con lit = HsApp (nlHsVar (dataConWrapId con)) (nlHsLit lit)

------------------------------
hsOverLitName :: OverLitVal -> Name
-- Get the canonical 'fromX' name for a particular OverLitVal
hsOverLitName (HsIntegral {})   = fromIntegerName
hsOverLitName (HsFractional {}) = fromRationalName
hsOverLitName (HsIsString {})   = fromStringName
\end{code}

%************************************************************************
%*									*
\subsection[BackSubst-HsBinds]{Running a substitution over @HsBinds@}
%*									*
%************************************************************************

\begin{code}
-- zonkId is used *during* typechecking just to zonk the Id's type
zonkId :: TcId -> TcM TcId
zonkId id
  = zonkTcType (idType id) `thenM` \ ty' ->
    returnM (Id.setIdType id ty')
\end{code}

The rest of the zonking is done *after* typechecking.
The main zonking pass runs over the bindings

 a) to convert TcTyVars to TyVars etc, dereferencing any bindings etc
 b) convert unbound TcTyVar to Void
 c) convert each TcId to an Id by zonking its type

The type variables are converted by binding mutable tyvars to immutable ones
and then zonking as normal.

The Ids are converted by binding them in the normal Tc envt; that
way we maintain sharing; eg an Id is zonked at its binding site and they
all occurrences of that Id point to the common zonked copy

It's all pretty boring stuff, because HsSyn is such a large type, and 
the environment manipulation is tiresome.

\begin{code}
type UnboundTyVarZonker = TcTyVar-> TcM Type 
	-- How to zonk an unbound type variable
        -- Note [Zonking the LHS of a RULE]

data ZonkEnv 
  = ZonkEnv 
      UnboundTyVarZonker
      (TyVarEnv TyVar)          -- 
      (IdEnv Var)		-- What variables are in scope
	-- Maps an Id or EvVar to its zonked version; both have the same Name
	-- Note that all evidence (coercion variables as well as dictionaries)
	-- 	are kept in the ZonkEnv
	-- Only *type* abstraction is done by side effect
	-- Is only consulted lazily; hence knot-tying

instance Outputable ZonkEnv where 
  ppr (ZonkEnv _ _ty_env var_env) = vcat (map ppr (varEnvElts var_env))


emptyZonkEnv :: ZonkEnv
emptyZonkEnv = ZonkEnv zonkTypeZapping emptyVarEnv emptyVarEnv

extendIdZonkEnv :: ZonkEnv -> [Var] -> ZonkEnv
extendIdZonkEnv (ZonkEnv zonk_ty ty_env id_env) ids 
  = ZonkEnv zonk_ty ty_env (extendVarEnvList id_env [(id,id) | id <- ids])

extendIdZonkEnv1 :: ZonkEnv -> Var -> ZonkEnv
extendIdZonkEnv1 (ZonkEnv zonk_ty ty_env id_env) id 
  = ZonkEnv zonk_ty ty_env (extendVarEnv id_env id id)

extendTyZonkEnv1 :: ZonkEnv -> TyVar -> ZonkEnv
extendTyZonkEnv1 (ZonkEnv zonk_ty ty_env id_env) ty
  = ZonkEnv zonk_ty (extendVarEnv ty_env ty ty) id_env

setZonkType :: ZonkEnv -> UnboundTyVarZonker -> ZonkEnv
setZonkType (ZonkEnv _ ty_env id_env) zonk_ty = ZonkEnv zonk_ty ty_env id_env

zonkEnvIds :: ZonkEnv -> [Id]
zonkEnvIds (ZonkEnv _ _ id_env) = varEnvElts id_env

zonkIdOcc :: ZonkEnv -> TcId -> Id
-- Ids defined in this module should be in the envt; 
-- ignore others.  (Actually, data constructors are also
-- not LocalVars, even when locally defined, but that is fine.)
-- (Also foreign-imported things aren't currently in the ZonkEnv;
--  that's ok because they don't need zonking.)
--
-- Actually, Template Haskell works in 'chunks' of declarations, and
-- an earlier chunk won't be in the 'env' that the zonking phase 
-- carries around.  Instead it'll be in the tcg_gbl_env, already fully
-- zonked.  There's no point in looking it up there (except for error 
-- checking), and it's not conveniently to hand; hence the simple
-- 'orElse' case in the LocalVar branch.
--
-- Even without template splices, in module Main, the checking of
-- 'main' is done as a separate chunk.
zonkIdOcc (ZonkEnv _zonk_ty _ty_env env) id 
  | isLocalVar id = lookupVarEnv env id `orElse` id
  | otherwise	  = id

zonkIdOccs :: ZonkEnv -> [TcId] -> [Id]
zonkIdOccs env ids = map (zonkIdOcc env) ids

-- zonkIdBndr is used *after* typechecking to get the Id's type
-- to its final form.  The TyVarEnv give 
zonkIdBndr :: ZonkEnv -> TcId -> TcM Id
zonkIdBndr env id
  = zonkTcTypeToType env (idType id)	`thenM` \ ty' ->
    returnM (Id.setIdType id ty')

zonkIdBndrs :: ZonkEnv -> [TcId] -> TcM [Id]
zonkIdBndrs env ids = mappM (zonkIdBndr env) ids

zonkTopBndrs :: [TcId] -> TcM [Id]
zonkTopBndrs ids = zonkIdBndrs emptyZonkEnv ids

zonkEvBndrsX :: ZonkEnv -> [EvVar] -> TcM (ZonkEnv, [Var])
zonkEvBndrsX = mapAccumLM zonkEvBndrX 

zonkEvBndrX :: ZonkEnv -> EvVar -> TcM (ZonkEnv, EvVar)
-- Works for dictionaries and coercions
zonkEvBndrX env var
  = do { var' <- zonkEvBndr env var
       ; return (extendIdZonkEnv1 env var', var') }

zonkEvBndr :: ZonkEnv -> EvVar -> TcM EvVar
-- Works for dictionaries and coercions
-- Does not extend the ZonkEnv
zonkEvBndr env var 
  = do { let var_ty = varType var
       ; ty <- 
           {-# SCC "zonkEvBndr_zonkTcTypeToType" #-}
           zonkTcTypeToType env var_ty
       ; return (setVarType var ty) }

zonkEvVarOcc :: ZonkEnv -> EvVar -> EvVar
zonkEvVarOcc env v = zonkIdOcc env v

zonkTyBndrsX :: ZonkEnv -> [TyVar] -> TcM (ZonkEnv, [TyVar])
zonkTyBndrsX = mapAccumLM zonkTyBndrX 

zonkTyBndrX :: ZonkEnv -> TyVar -> TcM (ZonkEnv, TyVar)
zonkTyBndrX env tv
  = do { tv' <- zonkTyBndr env tv
       ; return (extendTyZonkEnv1 env tv', tv') }

zonkTyBndr :: ZonkEnv -> TyVar -> TcM TyVar
zonkTyBndr env tv
  = do { ki <- zonkTcTypeToType env (tyVarKind tv)
       ; return (setVarType tv ki) }
\end{code}


\begin{code}
zonkTopExpr :: HsExpr TcId -> TcM (HsExpr Id)
zonkTopExpr e = zonkExpr emptyZonkEnv e

zonkTopLExpr :: LHsExpr TcId -> TcM (LHsExpr Id)
zonkTopLExpr e = zonkLExpr emptyZonkEnv e

zonkTopDecls :: Bag EvBind 
             -> LHsBinds TcId -> NameSet
             -> [LRuleDecl TcId] -> [LVectDecl TcId] -> [LTcSpecPrag] -> [LForeignDecl TcId]
             -> TcM ([Id], 
                     Bag EvBind,
                     Bag (LHsBind  Id),
                     [LForeignDecl Id],
                     [LTcSpecPrag],
                     [LRuleDecl    Id],
                     [LVectDecl    Id])
zonkTopDecls ev_binds binds sig_ns rules vects imp_specs fords
  = do  { (env1, ev_binds') <- zonkEvBinds emptyZonkEnv ev_binds

	 -- Warn about missing signatures
	 -- Do this only when we we have a type to offer
        ; warn_missing_sigs <- woptM Opt_WarnMissingSigs
        ; let sig_warn | warn_missing_sigs = topSigWarn sig_ns
                       | otherwise         = noSigWarn

        ; (env2, binds') <- zonkRecMonoBinds env1 sig_warn binds
                        -- Top level is implicitly recursive
        ; rules' <- zonkRules env2 rules
        ; vects' <- zonkVects env2 vects
        ; specs' <- zonkLTcSpecPrags env2 imp_specs
        ; fords' <- zonkForeignExports env2 fords
        ; return (zonkEnvIds env2, ev_binds', binds', fords', specs', rules', vects') }

---------------------------------------------
zonkLocalBinds :: ZonkEnv -> HsLocalBinds TcId -> TcM (ZonkEnv, HsLocalBinds Id)
zonkLocalBinds env EmptyLocalBinds
  = return (env, EmptyLocalBinds)

zonkLocalBinds _ (HsValBinds (ValBindsIn {}))
  = panic "zonkLocalBinds" -- Not in typechecker output

zonkLocalBinds env (HsValBinds vb@(ValBindsOut binds sigs))
  = do	{ warn_missing_sigs <- woptM Opt_WarnMissingLocalSigs
        ; let sig_warn | not warn_missing_sigs = noSigWarn
                       | otherwise             = localSigWarn sig_ns
              sig_ns = getTypeSigNames vb
	; (env1, new_binds) <- go env sig_warn binds
        ; return (env1, HsValBinds (ValBindsOut new_binds sigs)) }
  where
    go env _ []
      = return (env, [])
    go env sig_warn ((r,b):bs) 
      = do { (env1, b')  <- zonkRecMonoBinds env sig_warn b
	   ; (env2, bs') <- go env1 sig_warn bs
	   ; return (env2, (r,b'):bs') }

zonkLocalBinds env (HsIPBinds (IPBinds binds dict_binds))
  = mappM (wrapLocM zonk_ip_bind) binds	`thenM` \ new_binds ->
    let
	env1 = extendIdZonkEnv env [ipNameName n | L _ (IPBind n _) <- new_binds]
    in
    zonkTcEvBinds env1 dict_binds 	`thenM` \ (env2, new_dict_binds) -> 
    returnM (env2, HsIPBinds (IPBinds new_binds new_dict_binds))
  where
    zonk_ip_bind (IPBind n e)
	= mapIPNameTc (zonkIdBndr env) n	`thenM` \ n' ->
	  zonkLExpr env e			`thenM` \ e' ->
	  returnM (IPBind n' e')

---------------------------------------------
zonkRecMonoBinds :: ZonkEnv -> SigWarn -> LHsBinds TcId -> TcM (ZonkEnv, LHsBinds Id)
zonkRecMonoBinds env sig_warn binds 
 = fixM (\ ~(_, new_binds) -> do 
	{ let env1 = extendIdZonkEnv env (collectHsBindsBinders new_binds)
        ; binds' <- zonkMonoBinds env1 sig_warn binds
        ; return (env1, binds') })

---------------------------------------------
type SigWarn = Bool -> [Id] -> TcM ()	
     -- Missing-signature warning
     -- The Bool is True for an AbsBinds, False otherwise

noSigWarn :: SigWarn
noSigWarn _ _ = return ()

topSigWarn :: NameSet -> SigWarn
topSigWarn sig_ns _ ids = mapM_ (topSigWarnId sig_ns) ids

topSigWarnId :: NameSet -> Id -> TcM ()
-- The NameSet is the Ids that *lack* a signature
-- We have to do it this way round because there are
-- lots of top-level bindings that are generated by GHC
-- and that don't have signatures
topSigWarnId sig_ns id
  | idName id `elemNameSet` sig_ns = warnMissingSig msg id
  | otherwise                      = return ()
  where
    msg = ptext (sLit "Top-level binding with no type signature:")

localSigWarn :: NameSet -> SigWarn
localSigWarn sig_ns is_abs_bind ids
  | not is_abs_bind = return ()
  | otherwise       = mapM_ (localSigWarnId sig_ns) ids

localSigWarnId :: NameSet -> Id -> TcM ()
-- NameSet are the Ids that *have* type signatures
localSigWarnId sig_ns id
  | not (isSigmaTy (idType id))    = return ()
  | idName id `elemNameSet` sig_ns = return ()
  | otherwise                      = warnMissingSig msg id
  where
    msg = ptext (sLit "Polymophic local binding with no type signature:")

warnMissingSig :: SDoc -> Id -> TcM ()
warnMissingSig msg id
  = do  { env0 <- tcInitTidyEnv
        ; let (env1, tidy_ty) = tidyOpenType env0 (idType id)
        ; addWarnTcM (env1, mk_msg tidy_ty) }
  where
    mk_msg ty = sep [ msg, nest 2 $ pprPrefixName (idName id) <+> dcolon <+> ppr ty ]

---------------------------------------------
zonkMonoBinds :: ZonkEnv -> SigWarn -> LHsBinds TcId -> TcM (LHsBinds Id)
zonkMonoBinds env sig_warn binds = mapBagM (wrapLocM (zonk_bind env sig_warn)) binds

zonk_bind :: ZonkEnv -> SigWarn -> HsBind TcId -> TcM (HsBind Id)
zonk_bind env sig_warn bind@(PatBind { pat_lhs = pat, pat_rhs = grhss, pat_rhs_ty = ty})
  = do	{ (_env, new_pat) <- zonkPat env pat		-- Env already extended
        ; sig_warn False (collectPatBinders new_pat)
	; new_grhss <- zonkGRHSs env grhss
	; new_ty    <- zonkTcTypeToType env ty
	; return (bind { pat_lhs = new_pat, pat_rhs = new_grhss, pat_rhs_ty = new_ty }) }

zonk_bind env sig_warn (VarBind { var_id = var, var_rhs = expr, var_inline = inl })
  = do { new_var  <- zonkIdBndr env var
       ; sig_warn False [new_var]
       ; new_expr <- zonkLExpr env expr
       ; return (VarBind { var_id = new_var, var_rhs = new_expr, var_inline = inl }) }

zonk_bind env sig_warn bind@(FunBind { fun_id = L loc var, fun_matches = ms
                                     , fun_co_fn = co_fn })
  = do { new_var <- zonkIdBndr env var
       ; sig_warn False [new_var]
       ; (env1, new_co_fn) <- zonkCoFn env co_fn
       ; new_ms <- zonkMatchGroup env1 ms
       ; return (bind { fun_id = L loc new_var, fun_matches = new_ms
                      , fun_co_fn = new_co_fn }) }

zonk_bind env sig_warn (AbsBinds { abs_tvs = tyvars, abs_ev_vars = evs
                                 , abs_ev_binds = ev_binds
			         , abs_exports = exports
                                 , abs_binds = val_binds })
  = ASSERT( all isImmutableTyVar tyvars )
    do { (env0, new_tyvars) <- zonkTyBndrsX env tyvars
       ; (env1, new_evs) <- zonkEvBndrsX env0 evs
       ; (env2, new_ev_binds) <- zonkTcEvBinds env1 ev_binds
       ; (new_val_bind, new_exports) <- fixM $ \ ~(new_val_binds, _) ->
         do { let env3 = extendIdZonkEnv env2 (collectHsBindsBinders new_val_binds)
    	    ; new_val_binds <- zonkMonoBinds env3 noSigWarn val_binds
    	    ; new_exports   <- mapM (zonkExport env3) exports
    	    ; return (new_val_binds, new_exports) } 
       ; sig_warn True (map abe_poly new_exports)
       ; return (AbsBinds { abs_tvs = new_tyvars, abs_ev_vars = new_evs
                          , abs_ev_binds = new_ev_binds
			  , abs_exports = new_exports, abs_binds = new_val_bind }) }
  where
    zonkExport env (ABE{ abe_wrap = wrap, abe_poly = poly_id
                       , abe_mono = mono_id, abe_prags = prags })
	= zonkIdBndr env poly_id		`thenM` \ new_poly_id ->
	  zonkCoFn env wrap                     `thenM` \ (_, new_wrap) ->
          zonkSpecPrags env prags		`thenM` \ new_prags -> 
	  returnM (ABE{ abe_wrap = new_wrap, abe_poly = new_poly_id
                      , abe_mono = zonkIdOcc env mono_id, abe_prags = new_prags })

zonkSpecPrags :: ZonkEnv -> TcSpecPrags -> TcM TcSpecPrags
zonkSpecPrags _   IsDefaultMethod = return IsDefaultMethod
zonkSpecPrags env (SpecPrags ps)  = do { ps' <- zonkLTcSpecPrags env ps
                                       ; return (SpecPrags ps') }

zonkLTcSpecPrags :: ZonkEnv -> [LTcSpecPrag] -> TcM [LTcSpecPrag]
zonkLTcSpecPrags env ps
  = mapM zonk_prag ps
  where
    zonk_prag (L loc (SpecPrag id co_fn inl))
	= do { (_, co_fn') <- zonkCoFn env co_fn
	     ; return (L loc (SpecPrag (zonkIdOcc env id) co_fn' inl)) }
\end{code}

%************************************************************************
%*									*
\subsection[BackSubst-Match-GRHSs]{Match and GRHSs}
%*									*
%************************************************************************

\begin{code}
zonkMatchGroup :: ZonkEnv -> MatchGroup TcId-> TcM (MatchGroup Id)
zonkMatchGroup env (MatchGroup ms ty) 
  = do	{ ms' <- mapM (zonkMatch env) ms
	; ty' <- zonkTcTypeToType env ty
	; return (MatchGroup ms' ty') }

zonkMatch :: ZonkEnv -> LMatch TcId-> TcM (LMatch Id)
zonkMatch env (L loc (Match pats _ grhss))
  = do	{ (env1, new_pats) <- zonkPats env pats
	; new_grhss <- zonkGRHSs env1 grhss
	; return (L loc (Match new_pats Nothing new_grhss)) }

-------------------------------------------------------------------------
zonkGRHSs :: ZonkEnv -> GRHSs TcId -> TcM (GRHSs Id)

zonkGRHSs env (GRHSs grhss binds)
  = zonkLocalBinds env binds   	`thenM` \ (new_env, new_binds) ->
    let
	zonk_grhs (GRHS guarded rhs)
	  = zonkStmts new_env guarded	`thenM` \ (env2, new_guarded) ->
	    zonkLExpr env2 rhs		`thenM` \ new_rhs ->
	    returnM (GRHS new_guarded new_rhs)
    in
    mappM (wrapLocM zonk_grhs) grhss 	`thenM` \ new_grhss ->
    returnM (GRHSs new_grhss new_binds)
\end{code}

%************************************************************************
%*									*
\subsection[BackSubst-HsExpr]{Running a zonkitution over a TypeCheckedExpr}
%*									*
%************************************************************************

\begin{code}
zonkLExprs :: ZonkEnv -> [LHsExpr TcId] -> TcM [LHsExpr Id]
zonkLExpr  :: ZonkEnv -> LHsExpr TcId   -> TcM (LHsExpr Id)
zonkExpr   :: ZonkEnv -> HsExpr TcId    -> TcM (HsExpr Id)

zonkLExprs env exprs = mappM (zonkLExpr env) exprs
zonkLExpr  env expr  = wrapLocM (zonkExpr env) expr

zonkExpr env (HsVar id)
  = returnM (HsVar (zonkIdOcc env id))

zonkExpr env (HsIPVar id)
  = returnM (HsIPVar (mapIPName (zonkIdOcc env) id))

zonkExpr env (HsLit (HsRat f ty))
  = zonkTcTypeToType env ty	   `thenM` \ new_ty  ->
    returnM (HsLit (HsRat f new_ty))

zonkExpr _ (HsLit lit)
  = returnM (HsLit lit)

zonkExpr env (HsOverLit lit)
  = do	{ lit' <- zonkOverLit env lit
	; return (HsOverLit lit') }

zonkExpr env (HsLam matches)
  = zonkMatchGroup env matches	`thenM` \ new_matches ->
    returnM (HsLam new_matches)

zonkExpr env (HsApp e1 e2)
  = zonkLExpr env e1	`thenM` \ new_e1 ->
    zonkLExpr env e2	`thenM` \ new_e2 ->
    returnM (HsApp new_e1 new_e2)

zonkExpr env (HsBracketOut body bs) 
  = mappM zonk_b bs	`thenM` \ bs' ->
    returnM (HsBracketOut body bs')
  where
    zonk_b (n,e) = zonkLExpr env e	`thenM` \ e' ->
		   returnM (n,e')

zonkExpr _ (HsSpliceE s) = WARN( True, ppr s ) -- Should not happen
			     returnM (HsSpliceE s)

zonkExpr env (OpApp e1 op fixity e2)
  = zonkLExpr env e1	`thenM` \ new_e1 ->
    zonkLExpr env op	`thenM` \ new_op ->
    zonkLExpr env e2	`thenM` \ new_e2 ->
    returnM (OpApp new_e1 new_op fixity new_e2)

zonkExpr env (NegApp expr op)
  = zonkLExpr env expr	`thenM` \ new_expr ->
    zonkExpr env op	`thenM` \ new_op ->
    returnM (NegApp new_expr new_op)

zonkExpr env (HsPar e)    
  = zonkLExpr env e	`thenM` \new_e ->
    returnM (HsPar new_e)

zonkExpr env (SectionL expr op)
  = zonkLExpr env expr	`thenM` \ new_expr ->
    zonkLExpr env op		`thenM` \ new_op ->
    returnM (SectionL new_expr new_op)

zonkExpr env (SectionR op expr)
  = zonkLExpr env op		`thenM` \ new_op ->
    zonkLExpr env expr		`thenM` \ new_expr ->
    returnM (SectionR new_op new_expr)

zonkExpr env (ExplicitTuple tup_args boxed)
  = do { new_tup_args <- mapM zonk_tup_arg tup_args
       ; return (ExplicitTuple new_tup_args boxed) }
  where
    zonk_tup_arg (Present e) = do { e' <- zonkLExpr env e; return (Present e') }
    zonk_tup_arg (Missing t) = do { t' <- zonkTcTypeToType env t; return (Missing t') }

zonkExpr env (HsCase expr ms)
  = zonkLExpr env expr    	`thenM` \ new_expr ->
    zonkMatchGroup env ms	`thenM` \ new_ms ->
    returnM (HsCase new_expr new_ms)

zonkExpr env (HsIf e0 e1 e2 e3)
  = do { new_e0 <- fmapMaybeM (zonkExpr env) e0
       ; new_e1 <- zonkLExpr env e1
       ; new_e2 <- zonkLExpr env e2
       ; new_e3 <- zonkLExpr env e3
       ; returnM (HsIf new_e0 new_e1 new_e2 new_e3) }

zonkExpr env (HsLet binds expr)
  = zonkLocalBinds env binds	`thenM` \ (new_env, new_binds) ->
    zonkLExpr new_env expr	`thenM` \ new_expr ->
    returnM (HsLet new_binds new_expr)

zonkExpr env (HsAlet binds expr aletTooling) = -- panic "appfix: zonkExpr not implemented"
  do (new_env, new_binds) <- zonkLocalBinds env binds	
     new_expr <- zonkLExpr new_env expr
     return (HsAlet new_binds new_expr aletTooling)

zonkExpr env (HsDo do_or_lc stmts ty)
  = zonkStmts env stmts 	`thenM` \ (_, new_stmts) ->
    zonkTcTypeToType env ty	`thenM` \ new_ty   ->
    returnM (HsDo do_or_lc new_stmts new_ty)

zonkExpr env (ExplicitList ty exprs)
  = zonkTcTypeToType env ty	`thenM` \ new_ty ->
    zonkLExprs env exprs	`thenM` \ new_exprs ->
    returnM (ExplicitList new_ty new_exprs)

zonkExpr env (ExplicitPArr ty exprs)
  = zonkTcTypeToType env ty	`thenM` \ new_ty ->
    zonkLExprs env exprs	`thenM` \ new_exprs ->
    returnM (ExplicitPArr new_ty new_exprs)

zonkExpr env (RecordCon data_con con_expr rbinds)
  = do	{ new_con_expr <- zonkExpr env con_expr
	; new_rbinds   <- zonkRecFields env rbinds
	; return (RecordCon data_con new_con_expr new_rbinds) }

zonkExpr env (RecordUpd expr rbinds cons in_tys out_tys)
  = do	{ new_expr    <- zonkLExpr env expr
	; new_in_tys  <- mapM (zonkTcTypeToType env) in_tys
	; new_out_tys <- mapM (zonkTcTypeToType env) out_tys
	; new_rbinds  <- zonkRecFields env rbinds
	; return (RecordUpd new_expr new_rbinds cons new_in_tys new_out_tys) }

zonkExpr env (ExprWithTySigOut e ty) 
  = do { e' <- zonkLExpr env e
       ; return (ExprWithTySigOut e' ty) }

zonkExpr _ (ExprWithTySig _ _) = panic "zonkExpr env:ExprWithTySig"

zonkExpr env (ArithSeq expr info)
  = zonkExpr env expr		`thenM` \ new_expr ->
    zonkArithSeq env info	`thenM` \ new_info ->
    returnM (ArithSeq new_expr new_info)

zonkExpr env (PArrSeq expr info)
  = zonkExpr env expr		`thenM` \ new_expr ->
    zonkArithSeq env info	`thenM` \ new_info ->
    returnM (PArrSeq new_expr new_info)

zonkExpr env (HsSCC lbl expr)
  = zonkLExpr env expr	`thenM` \ new_expr ->
    returnM (HsSCC lbl new_expr)

zonkExpr env (HsTickPragma info expr)
  = zonkLExpr env expr	`thenM` \ new_expr ->
    returnM (HsTickPragma info new_expr)

-- hdaume: core annotations
zonkExpr env (HsCoreAnn lbl expr)
  = zonkLExpr env expr   `thenM` \ new_expr ->
    returnM (HsCoreAnn lbl new_expr)

-- arrow notation extensions
zonkExpr env (HsProc pat body)
  = do	{ (env1, new_pat) <- zonkPat env pat
	; new_body <- zonkCmdTop env1 body
	; return (HsProc new_pat new_body) }

zonkExpr env (HsArrApp e1 e2 ty ho rl)
  = zonkLExpr env e1	    	    	`thenM` \ new_e1 ->
    zonkLExpr env e2	    	    	`thenM` \ new_e2 ->
    zonkTcTypeToType env ty 		`thenM` \ new_ty ->
    returnM (HsArrApp new_e1 new_e2 new_ty ho rl)

zonkExpr env (HsArrForm op fixity args)
  = zonkLExpr env op	    	    	`thenM` \ new_op ->
    mappM (zonkCmdTop env) args		`thenM` \ new_args ->
    returnM (HsArrForm new_op fixity new_args)

zonkExpr env (HsWrap co_fn expr)
  = zonkCoFn env co_fn	`thenM` \ (env1, new_co_fn) ->
    zonkExpr env1 expr	`thenM` \ new_expr ->
    return (HsWrap new_co_fn new_expr)

zonkExpr _ expr = pprPanic "zonkExpr" (ppr expr)

zonkCmdTop :: ZonkEnv -> LHsCmdTop TcId -> TcM (LHsCmdTop Id)
zonkCmdTop env cmd = wrapLocM (zonk_cmd_top env) cmd

zonk_cmd_top :: ZonkEnv -> HsCmdTop TcId -> TcM (HsCmdTop Id)
zonk_cmd_top env (HsCmdTop cmd stack_tys ty ids)
  = zonkLExpr env cmd	    		`thenM` \ new_cmd ->
    zonkTcTypeToTypes env stack_tys	`thenM` \ new_stack_tys ->
    zonkTcTypeToType env ty 		`thenM` \ new_ty ->
    mapSndM (zonkExpr env) ids		`thenM` \ new_ids ->
    returnM (HsCmdTop new_cmd new_stack_tys new_ty new_ids)

-------------------------------------------------------------------------
zonkCoFn :: ZonkEnv -> HsWrapper -> TcM (ZonkEnv, HsWrapper)
zonkCoFn env WpHole   = return (env, WpHole)
zonkCoFn env (WpCompose c1 c2) = do { (env1, c1') <- zonkCoFn env c1
				    ; (env2, c2') <- zonkCoFn env1 c2
				    ; return (env2, WpCompose c1' c2') }
zonkCoFn env (WpCast co) = do { co' <- zonkTcLCoToLCo env co
			      ; return (env, WpCast co') }
zonkCoFn env (WpEvLam ev)   = do { (env', ev') <- zonkEvBndrX env ev
				 ; return (env', WpEvLam ev') }
zonkCoFn env (WpEvApp arg)  = do { arg' <- zonkEvTerm env arg 
                                 ; return (env, WpEvApp arg') }
zonkCoFn env (WpTyLam tv)   = ASSERT( isImmutableTyVar tv )
                              do { (env', tv') <- zonkTyBndrX env tv
				 ; return (env', WpTyLam tv') }
zonkCoFn env (WpTyApp ty)   = do { ty' <- zonkTcTypeToType env ty
				 ; return (env, WpTyApp ty') }
zonkCoFn env (WpLet bs)     = do { (env1, bs') <- zonkTcEvBinds env bs
				 ; return (env1, WpLet bs') }

-------------------------------------------------------------------------
zonkOverLit :: ZonkEnv -> HsOverLit TcId -> TcM (HsOverLit Id)
zonkOverLit env lit@(OverLit { ol_witness = e, ol_type = ty })
  = do	{ ty' <- zonkTcTypeToType env ty
	; e' <- zonkExpr env e
 	; return (lit { ol_witness = e', ol_type = ty' }) }

-------------------------------------------------------------------------
zonkArithSeq :: ZonkEnv -> ArithSeqInfo TcId -> TcM (ArithSeqInfo Id)

zonkArithSeq env (From e)
  = zonkLExpr env e		`thenM` \ new_e ->
    returnM (From new_e)

zonkArithSeq env (FromThen e1 e2)
  = zonkLExpr env e1	`thenM` \ new_e1 ->
    zonkLExpr env e2	`thenM` \ new_e2 ->
    returnM (FromThen new_e1 new_e2)

zonkArithSeq env (FromTo e1 e2)
  = zonkLExpr env e1	`thenM` \ new_e1 ->
    zonkLExpr env e2	`thenM` \ new_e2 ->
    returnM (FromTo new_e1 new_e2)

zonkArithSeq env (FromThenTo e1 e2 e3)
  = zonkLExpr env e1	`thenM` \ new_e1 ->
    zonkLExpr env e2	`thenM` \ new_e2 ->
    zonkLExpr env e3	`thenM` \ new_e3 ->
    returnM (FromThenTo new_e1 new_e2 new_e3)


-------------------------------------------------------------------------
zonkStmts :: ZonkEnv -> [LStmt TcId] -> TcM (ZonkEnv, [LStmt Id])
zonkStmts env []     = return (env, [])
zonkStmts env (s:ss) = do { (env1, s')  <- wrapLocSndM (zonkStmt env) s
			  ; (env2, ss') <- zonkStmts env1 ss
			  ; return (env2, s' : ss') }

zonkStmt :: ZonkEnv -> Stmt TcId -> TcM (ZonkEnv, Stmt Id)
zonkStmt env (ParStmt stmts_w_bndrs mzip_op bind_op return_op)
  = mappM zonk_branch stmts_w_bndrs	`thenM` \ new_stmts_w_bndrs ->
    let 
	new_binders = concat (map snd new_stmts_w_bndrs)
	env1 = extendIdZonkEnv env new_binders
    in
    zonkExpr env1 mzip_op   `thenM` \ new_mzip ->
    zonkExpr env1 bind_op   `thenM` \ new_bind ->
    zonkExpr env1 return_op `thenM` \ new_return ->
    return (env1, ParStmt new_stmts_w_bndrs new_mzip new_bind new_return)
  where
    zonk_branch (stmts, bndrs) = zonkStmts env stmts	`thenM` \ (env1, new_stmts) ->
				 returnM (new_stmts, zonkIdOccs env1 bndrs)

zonkStmt env (RecStmt { recS_stmts = segStmts, recS_later_ids = lvs, recS_rec_ids = rvs
                      , recS_ret_fn = ret_id, recS_mfix_fn = mfix_id, recS_bind_fn = bind_id
                      , recS_later_rets = later_rets, recS_rec_rets = rec_rets
                      , recS_ret_ty = ret_ty })
  = do { new_rvs <- zonkIdBndrs env rvs
       ; new_lvs <- zonkIdBndrs env lvs
       ; new_ret_ty  <- zonkTcTypeToType env ret_ty
       ; new_ret_id  <- zonkExpr env ret_id
       ; new_mfix_id <- zonkExpr env mfix_id
       ; new_bind_id <- zonkExpr env bind_id
       ; let env1 = extendIdZonkEnv env new_rvs
       ; (env2, new_segStmts) <- zonkStmts env1 segStmts
	-- Zonk the ret-expressions in an envt that 
	-- has the polymorphic bindings in the envt
       ; new_later_rets <- mapM (zonkExpr env2) later_rets
       ; new_rec_rets <- mapM (zonkExpr env2) rec_rets
       ; return (extendIdZonkEnv env new_lvs,     -- Only the lvs are needed
                 RecStmt { recS_stmts = new_segStmts, recS_later_ids = new_lvs
                         , recS_rec_ids = new_rvs, recS_ret_fn = new_ret_id
                         , recS_mfix_fn = new_mfix_id, recS_bind_fn = new_bind_id
                         , recS_later_rets = new_later_rets
                         , recS_rec_rets = new_rec_rets, recS_ret_ty = new_ret_ty }) }

zonkStmt env (ExprStmt expr then_op guard_op ty)
  = zonkLExpr env expr		`thenM` \ new_expr ->
    zonkExpr env then_op	`thenM` \ new_then ->
    zonkExpr env guard_op	`thenM` \ new_guard ->
    zonkTcTypeToType env ty	`thenM` \ new_ty ->
    returnM (env, ExprStmt new_expr new_then new_guard new_ty)

zonkStmt env (LastStmt expr ret_op)
  = zonkLExpr env expr		`thenM` \ new_expr ->
    zonkExpr env ret_op		`thenM` \ new_ret ->
    returnM (env, LastStmt new_expr new_ret)

zonkStmt env (TransStmt { trS_stmts = stmts, trS_bndrs = binderMap
                        , trS_by = by, trS_form = form, trS_using = using
                        , trS_ret = return_op, trS_bind = bind_op, trS_fmap = liftM_op })
  = do { (env', stmts') <- zonkStmts env stmts 
    ; binderMap' <- mappM (zonkBinderMapEntry env') binderMap
    ; by'        <- fmapMaybeM (zonkLExpr env') by
    ; using'     <- zonkLExpr env using
    ; return_op' <- zonkExpr env' return_op
    ; bind_op'   <- zonkExpr env' bind_op
    ; liftM_op'  <- zonkExpr env' liftM_op
    ; let env'' = extendIdZonkEnv env' (map snd binderMap')
    ; return (env'', TransStmt { trS_stmts = stmts', trS_bndrs = binderMap'
                               , trS_by = by', trS_form = form, trS_using = using'
                               , trS_ret = return_op', trS_bind = bind_op', trS_fmap = liftM_op' }) }
  where
    zonkBinderMapEntry env (oldBinder, newBinder) = do 
        let oldBinder' = zonkIdOcc env oldBinder
        newBinder' <- zonkIdBndr env newBinder
        return (oldBinder', newBinder') 

zonkStmt env (LetStmt binds)
  = zonkLocalBinds env binds	`thenM` \ (env1, new_binds) ->
    returnM (env1, LetStmt new_binds)

zonkStmt env (BindStmt pat expr bind_op fail_op)
  = do	{ new_expr <- zonkLExpr env expr
	; (env1, new_pat) <- zonkPat env pat
	; new_bind <- zonkExpr env bind_op
	; new_fail <- zonkExpr env fail_op
	; return (env1, BindStmt new_pat new_expr new_bind new_fail) }

-------------------------------------------------------------------------
zonkRecFields :: ZonkEnv -> HsRecordBinds TcId -> TcM (HsRecordBinds TcId)
zonkRecFields env (HsRecFields flds dd)
  = do	{ flds' <- mappM zonk_rbind flds
	; return (HsRecFields flds' dd) }
  where
    zonk_rbind fld
      = do { new_id   <- wrapLocM (zonkIdBndr env) (hsRecFieldId fld)
	   ; new_expr <- zonkLExpr env (hsRecFieldArg fld)
	   ; return (fld { hsRecFieldId = new_id, hsRecFieldArg = new_expr }) }

-------------------------------------------------------------------------
mapIPNameTc :: (a -> TcM b) -> IPName a -> TcM (IPName b)
mapIPNameTc f (IPName n) = f n  `thenM` \ r -> returnM (IPName r)
\end{code}


%************************************************************************
%*									*
\subsection[BackSubst-Pats]{Patterns}
%*									*
%************************************************************************

\begin{code}
zonkPat :: ZonkEnv -> OutPat TcId -> TcM (ZonkEnv, OutPat Id)
-- Extend the environment as we go, because it's possible for one
-- pattern to bind something that is used in another (inside or
-- to the right)
zonkPat env pat = wrapLocSndM (zonk_pat env) pat

zonk_pat :: ZonkEnv -> Pat TcId -> TcM (ZonkEnv, Pat Id)
zonk_pat env (ParPat p)
  = do	{ (env', p') <- zonkPat env p
  	; return (env', ParPat p') }

zonk_pat env (WildPat ty)
  = do	{ ty' <- zonkTcTypeToType env ty
	; return (env, WildPat ty') }

zonk_pat env (VarPat v)
  = do	{ v' <- zonkIdBndr env v
	; return (extendIdZonkEnv1 env v', VarPat v') }

zonk_pat env (LazyPat pat)
  = do	{ (env', pat') <- zonkPat env pat
	; return (env',  LazyPat pat') }

zonk_pat env (BangPat pat)
  = do	{ (env', pat') <- zonkPat env pat
	; return (env',  BangPat pat') }

zonk_pat env (AsPat (L loc v) pat)
  = do	{ v' <- zonkIdBndr env v
	; (env', pat') <- zonkPat (extendIdZonkEnv1 env v') pat
 	; return (env', AsPat (L loc v') pat') }

zonk_pat env (ViewPat expr pat ty)
  = do	{ expr' <- zonkLExpr env expr
	; (env', pat') <- zonkPat env pat
 	; ty' <- zonkTcTypeToType env ty
	; return (env', ViewPat expr' pat' ty') }

zonk_pat env (ListPat pats ty)
  = do	{ ty' <- zonkTcTypeToType env ty
	; (env', pats') <- zonkPats env pats
	; return (env', ListPat pats' ty') }

zonk_pat env (PArrPat pats ty)
  = do	{ ty' <- zonkTcTypeToType env ty
	; (env', pats') <- zonkPats env pats
	; return (env', PArrPat pats' ty') }

zonk_pat env (TuplePat pats boxed ty)
  = do	{ ty' <- zonkTcTypeToType env ty
	; (env', pats') <- zonkPats env pats
	; return (env', TuplePat pats' boxed ty') }

zonk_pat env p@(ConPatOut { pat_ty = ty, pat_dicts = evs, pat_binds = binds, pat_args = args })
  = ASSERT( all isImmutableTyVar (pat_tvs p) ) 
    do	{ new_ty <- zonkTcTypeToType env ty
	; (env1, new_evs) <- zonkEvBndrsX env evs
	; (env2, new_binds) <- zonkTcEvBinds env1 binds
	; (env', new_args) <- zonkConStuff env2 args
	; returnM (env', p { pat_ty = new_ty, pat_dicts = new_evs, 
			     pat_binds = new_binds, pat_args = new_args }) }

zonk_pat env (LitPat lit) = return (env, LitPat lit)

zonk_pat env (SigPatOut pat ty)
  = do	{ ty' <- zonkTcTypeToType env ty
	; (env', pat') <- zonkPat env pat
	; return (env', SigPatOut pat' ty') }

zonk_pat env (NPat lit mb_neg eq_expr)
  = do	{ lit' <- zonkOverLit env lit
 	; mb_neg' <- fmapMaybeM (zonkExpr env) mb_neg
 	; eq_expr' <- zonkExpr env eq_expr
	; return (env, NPat lit' mb_neg' eq_expr') }

zonk_pat env (NPlusKPat (L loc n) lit e1 e2)
  = do	{ n' <- zonkIdBndr env n
	; lit' <- zonkOverLit env lit
 	; e1' <- zonkExpr env e1
	; e2' <- zonkExpr env e2
	; return (extendIdZonkEnv1 env n', NPlusKPat (L loc n') lit' e1' e2') }

zonk_pat env (CoPat co_fn pat ty) 
  = do { (env', co_fn') <- zonkCoFn env co_fn
       ; (env'', pat') <- zonkPat env' (noLoc pat)
       ; ty' <- zonkTcTypeToType env'' ty
       ; return (env'', CoPat co_fn' (unLoc pat') ty') }

zonk_pat _ pat = pprPanic "zonk_pat" (ppr pat)

---------------------------
zonkConStuff :: ZonkEnv
             -> HsConDetails (OutPat TcId) (HsRecFields id (OutPat TcId))
             -> TcM (ZonkEnv,
                     HsConDetails (OutPat Id) (HsRecFields id (OutPat Id)))
zonkConStuff env (PrefixCon pats)
  = do	{ (env', pats') <- zonkPats env pats
	; return (env', PrefixCon pats') }

zonkConStuff env (InfixCon p1 p2)
  = do	{ (env1, p1') <- zonkPat env  p1
	; (env', p2') <- zonkPat env1 p2
	; return (env', InfixCon p1' p2') }

zonkConStuff env (RecCon (HsRecFields rpats dd))
  = do	{ (env', pats') <- zonkPats env (map hsRecFieldArg rpats)
	; let rpats' = zipWith (\rp p' -> rp { hsRecFieldArg = p' }) rpats pats'
	; returnM (env', RecCon (HsRecFields rpats' dd)) }
	-- Field selectors have declared types; hence no zonking

---------------------------
zonkPats :: ZonkEnv -> [OutPat TcId] -> TcM (ZonkEnv, [OutPat Id])
zonkPats env []		= return (env, [])
zonkPats env (pat:pats) = do { (env1, pat') <- zonkPat env pat
		     ; (env', pats') <- zonkPats env1 pats
		     ; return (env', pat':pats') }
\end{code}

%************************************************************************
%*									*
\subsection[BackSubst-Foreign]{Foreign exports}
%*									*
%************************************************************************


\begin{code}
zonkForeignExports :: ZonkEnv -> [LForeignDecl TcId] -> TcM [LForeignDecl Id]
zonkForeignExports env ls = mappM (wrapLocM (zonkForeignExport env)) ls

zonkForeignExport :: ZonkEnv -> ForeignDecl TcId -> TcM (ForeignDecl Id)
zonkForeignExport env (ForeignExport i _hs_ty co spec) =
   returnM (ForeignExport (fmap (zonkIdOcc env) i) undefined co spec)
zonkForeignExport _ for_imp 
  = returnM for_imp	-- Foreign imports don't need zonking
\end{code}

\begin{code}
zonkRules :: ZonkEnv -> [LRuleDecl TcId] -> TcM [LRuleDecl Id]
zonkRules env rs = mappM (wrapLocM (zonkRule env)) rs

zonkRule :: ZonkEnv -> RuleDecl TcId -> TcM (RuleDecl Id)
zonkRule env (HsRule name act (vars{-::[RuleBndr TcId]-}) lhs fv_lhs rhs fv_rhs)
  = do { unbound_tkv_set <- newMutVar emptyVarSet
       ; let env_rule = setZonkType env (zonkTvCollecting unbound_tkv_set)
              -- See Note [Zonking the LHS of a RULE]

       ; (env_inside, new_bndrs) <- mapAccumLM zonk_bndr env_rule vars

       ; new_lhs <- zonkLExpr env_inside lhs
       ; new_rhs <- zonkLExpr env_inside rhs

       ; unbound_tkvs <- readMutVar unbound_tkv_set

       ; let final_bndrs :: [RuleBndr Var]
             final_bndrs = map (RuleBndr . noLoc)
                             (varSetElemsKvsFirst unbound_tkvs)
                           ++ new_bndrs

       ; return (HsRule name act final_bndrs new_lhs fv_lhs new_rhs fv_rhs) }
  where
   zonk_bndr env (RuleBndr (L loc v)) 
      = do { (env', v') <- zonk_it env v; return (env', RuleBndr (L loc v')) }
   zonk_bndr _ (RuleBndrSig {}) = panic "zonk_bndr RuleBndrSig"

   zonk_it env v
     | isId v     = do { v' <- zonkIdBndr env v; return (extendIdZonkEnv1 env v', v') }
     | otherwise  = ASSERT( isImmutableTyVar v) return (env, v)
\end{code}

\begin{code}
zonkVects :: ZonkEnv -> [LVectDecl TcId] -> TcM [LVectDecl Id]
zonkVects env = mappM (wrapLocM (zonkVect env))

zonkVect :: ZonkEnv -> VectDecl TcId -> TcM (VectDecl Id)
zonkVect env (HsVect v e)
  = do { v' <- wrapLocM (zonkIdBndr env) v
       ; e' <- fmapMaybeM (zonkLExpr env) e
       ; return $ HsVect v' e'
       }
zonkVect env (HsNoVect v)
  = do { v' <- wrapLocM (zonkIdBndr env) v
       ; return $ HsNoVect v'
       }
zonkVect _env (HsVectTypeOut s t rt)
  = return $ HsVectTypeOut s t rt
zonkVect _ (HsVectTypeIn _ _ _) = panic "TcHsSyn.zonkVect: HsVectTypeIn"
zonkVect _env (HsVectClassOut c)
  = return $ HsVectClassOut c
zonkVect _ (HsVectClassIn _) = panic "TcHsSyn.zonkVect: HsVectClassIn"
zonkVect _env (HsVectInstOut i)
  = return $ HsVectInstOut i
zonkVect _ (HsVectInstIn _) = panic "TcHsSyn.zonkVect: HsVectInstIn"
\end{code}

%************************************************************************
%*									*
              Constraints and evidence
%*									*
%************************************************************************

\begin{code}
zonkEvTerm :: ZonkEnv -> EvTerm -> TcM EvTerm
zonkEvTerm env (EvId v)           = ASSERT2( isId v, ppr v ) 
                                    return (EvId (zonkIdOcc env v))
zonkEvTerm env (EvCoercion co)    = do { co' <- zonkTcLCoToLCo env co
                                       ; return (EvCoercion co') }
zonkEvTerm env (EvCast v co)      = ASSERT( isId v) 
                                    do { co' <- zonkTcLCoToLCo env co
                                       ; return (mkEvCast (zonkIdOcc env v) co') }
zonkEvTerm env (EvTupleSel v n)   = return (EvTupleSel (zonkIdOcc env v) n)
zonkEvTerm env (EvTupleMk vs)     = return (EvTupleMk (map (zonkIdOcc env) vs))
zonkEvTerm env (EvSuperClass d n) = return (EvSuperClass (zonkIdOcc env d) n)
zonkEvTerm env (EvDFunApp df tys tms)
  = do { tys' <- zonkTcTypeToTypes env tys
       ; let tms' = map (zonkEvVarOcc env) tms
       ; return (EvDFunApp (zonkIdOcc env df) tys' tms') }

zonkTcEvBinds :: ZonkEnv -> TcEvBinds -> TcM (ZonkEnv, TcEvBinds)
zonkTcEvBinds env (TcEvBinds var) = do { (env', bs') <- zonkEvBindsVar env var
				       ; return (env', EvBinds bs') }
zonkTcEvBinds env (EvBinds bs)    = do { (env', bs') <- zonkEvBinds env bs
				       ; return (env', EvBinds bs') }

zonkEvBindsVar :: ZonkEnv -> EvBindsVar -> TcM (ZonkEnv, Bag EvBind)
zonkEvBindsVar env (EvBindsVar ref _) = do { bs <- readMutVar ref
                                           ; zonkEvBinds env (evBindMapBinds bs) }

zonkEvBinds :: ZonkEnv -> Bag EvBind -> TcM (ZonkEnv, Bag EvBind)
zonkEvBinds env binds
  = {-# SCC "zonkEvBinds" #-}
    fixM (\ ~( _, new_binds) -> do
	 { let env1 = extendIdZonkEnv env (collect_ev_bndrs new_binds)
         ; binds' <- mapBagM (zonkEvBind env1) binds
         ; return (env1, binds') })
  where
    collect_ev_bndrs :: Bag EvBind -> [EvVar]
    collect_ev_bndrs = foldrBag add [] 
    add (EvBind var _) vars = var : vars

zonkEvBind :: ZonkEnv -> EvBind -> TcM EvBind
zonkEvBind env (EvBind var term)
  -- This function has some special cases for avoiding re-zonking the
  -- same types many types. See Note [Optimized Evidence Binding Zonking]
  = case term of 
      -- Fast path for reflexivity coercions:
      EvCoercion co 
        | Just ty <- isTcReflCo_maybe co
        ->
          do { zty  <- zonkTcTypeToType env ty
             ; let var' = setVarType var (mkEqPred (zty,zty))
             ; return (EvBind var' (EvCoercion (mkTcReflCo zty))) }

      -- Fast path for variable-variable bindings 
      -- NB: could be optimized further! (e.g. SymCo cv)
        | Just cv <- getTcCoVar_maybe co 
        -> do { let cv' = zonkIdOcc env cv -- Just lazily look up
                    term' = EvCoercion (TcCoVarCo cv')
                    var'  = setVarType var (varType cv')
              ; return (EvBind var' term') }
      -- Ugly safe and slow path
      _ -> do { var'  <- {-# SCC "zonkEvBndr" #-} zonkEvBndr env var
              ; term' <- zonkEvTerm env term 
              ; return (EvBind var' term')
              }
\end{code}

%************************************************************************
%*									*
                         Zonking types
%*									*
%************************************************************************

Note [Zonking the LHS of a RULE]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
We need to gather the type variables mentioned on the LHS so we can 
quantify over them.  Example:
  data T a = C

  foo :: T a -> Int
  foo C = 1

  {-# RULES "myrule"  foo C = 1 #-}

After type checking the LHS becomes (foo a (C a))
and we do not want to zap the unbound tyvar 'a' to (), because
that limits the applicability of the rule.  Instead, we
want to quantify over it!  

It's easiest to get zonkTvCollecting to gather the free tyvars
here. Attempts to do so earlier are tiresome, because (a) the data
type is big and (b) finding the free type vars of an expression is
necessarily monadic operation. (consider /\a -> f @ b, where b is
side-effected to a)

And that in turn is why ZonkEnv carries the function to use for
type variables!

Note [Zonking mutable unbound type or kind variables]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
In zonkTypeZapping, we zonk mutable but unbound type or kind variables to an
arbitrary type. We know if they are unbound even though we don't carry an
environment, because at the binding site for a variable we bind the mutable
var to a fresh immutable one.  So the mutable store plays the role of an
environment.  If we come across a mutable variable that isn't so bound, it
must be completely free. We zonk the expected kind to make sure we don't get
some unbound meta variable as the kind.

Note that since we have kind polymorphism, zonk_unbound_tyvar will handle both
type and kind variables. Consider the following datatype:

  data Phantom a = Phantom Int

The type of Phantom is (forall (k : BOX). forall (a : k). Int). Both `a` and
`k` are unbound variables. We want to zonk this to
(forall (k : AnyK). forall (a : Any AnyK). Int). For that we have to check if
we have a type or a kind variable; for kind variables we just return AnyK (and
not the ill-kinded Any BOX).

Note [Optimized Evidence Binding Zonking]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

When optimising evidence binds we may come accross situations where 
a coercion is just reflexivity: 
      cv = ReflCo ty
In such a case it is a waste of time to zonk both ty and the type 
of the coercion, especially if the types involved are huge. For this
reason this case is optimized to only zonk 'ty' and set the type of 
the variable to be that zonked type.

Another case that hurts a lot are simple coercion bindings of the form:
      cv1 = cv2
      cv3 = cv1
      cv4 = cv2 
etc. In all such cases it is very easy to just get the zonked type of 
cv2 and use it to set the type of the LHS coercion variable without zonking
twice. Though this case is funny, it can happen due the way that evidence 
from spontaneously solved goals is now used.
See Note [Optimizing Spontaneously Solved Goals] about this.

NB: That these optimizations are independently useful, regardless of the 
constraint solver strategy.

DV, TODO: followup on this note mentioning new examples I will add to perf/


\begin{code}
mkZonkTcTyVar :: (TcTyVar -> TcM Type)	-- What to do for an *mutable Flexi* var
	      -> (TcTyVar -> Type)	-- What to do for an immutable var
 	      -> TcTyVar -> TcM TcType
mkZonkTcTyVar unbound_mvar_fn unbound_ivar_fn
  = zonk_tv
  where
    zonk_tv tv 
     = ASSERT( isTcTyVar tv )
       case tcTyVarDetails tv of
         SkolemTv {}    -> return (unbound_ivar_fn tv)
         RuntimeUnk {}  -> return (unbound_ivar_fn tv)
         FlatSkol ty    -> zonkType zonk_tv ty
         MetaTv _ ref   -> do { cts <- readMutVar ref
           		      ; case cts of    
           		           Flexi -> do { kind <- {-# SCC "zonkKind1" #-}
                                                         zonkType zonk_tv (tyVarKind tv)
                                               ; unbound_mvar_fn (setTyVarKind tv kind) }
           		           Indirect ty -> do { zty <- zonkType zonk_tv ty 
                                                     -- Small optimisation: shortern-out indirect steps
                                                     -- so that the old type may be more easily collected.
                                                     ; writeMutVar ref (Indirect zty)
                                                     ; return zty } }

zonkTcTypeToType :: ZonkEnv -> TcType -> TcM Type
zonkTcTypeToType (ZonkEnv zonk_unbound_tyvar tv_env _id_env)
  = zonkType (mkZonkTcTyVar zonk_unbound_tyvar zonk_bound_tyvar)
  where
    zonk_bound_tyvar tv = case lookupVarEnv tv_env tv of
                            Nothing  -> mkTyVarTy tv
                            Just tv' -> mkTyVarTy tv'

zonkTcTypeToTypes :: ZonkEnv -> [TcType] -> TcM [Type]
zonkTcTypeToTypes env tys = mapM (zonkTcTypeToType env) tys

zonkTvCollecting :: TcRef TyVarSet -> UnboundTyVarZonker
-- This variant collects unbound type variables in a mutable variable
-- Works on both types and kinds
zonkTvCollecting unbound_tv_set tv
  = do { poly_kinds <- xoptM Opt_PolyKinds
       ; if isKiVar tv && not poly_kinds then defaultKindVarToStar tv
         else do
       { tv' <- zonkQuantifiedTyVar tv
       ; tv_set <- readMutVar unbound_tv_set
       ; writeMutVar unbound_tv_set (extendVarSet tv_set tv')
       ; return (mkTyVarTy tv') } }

zonkTypeZapping :: UnboundTyVarZonker
-- This variant is used for everything except the LHS of rules
-- It zaps unbound type variables to (), or some other arbitrary type
-- Works on both types and kinds
zonkTypeZapping tv
  = do { let ty = if isKiVar tv
                  -- ty is actually a kind, zonk to AnyK
                  then anyKind
                  else anyTypeOfKind (tyVarKind tv)
       ; writeMetaTyVar tv ty
       ; return ty }


zonkTcLCoToLCo :: ZonkEnv -> TcCoercion -> TcM TcCoercion
-- NB: zonking often reveals that the coercion is an identity
--     in which case the Refl-ness can propagate up to the top
--     which in turn gives more efficient desugaring.  So it's
--     worth using the 'mk' smart constructors on the RHS
zonkTcLCoToLCo env co
  = go co
  where
    go (TcLetCo bs co)        = do { (env', bs') <- zonkTcEvBinds env bs
                                   ; co' <- zonkTcLCoToLCo env' co
                                   ; return (TcLetCo bs' co') }
    go (TcCoVarCo cv)         = return (mkTcCoVarCo (zonkEvVarOcc env cv))
    go (TcRefl ty)            = do { ty' <- zonkTcTypeToType env ty
                                   ; return (TcRefl ty') }
    go (TcTyConAppCo tc cos)  = do { cos' <- mapM go cos; return (mkTcTyConAppCo tc cos') }
    go (TcAxiomInstCo ax tys) = do { tys' <- zonkTcTypeToTypes env tys; return (TcAxiomInstCo ax tys') }
    go (TcAppCo co1 co2)      = do { co1' <- go co1; co2' <- go co2
                                   ; return (mkTcAppCo co1' co2') }
    go (TcSymCo co)           = do { co' <- go co; return (mkTcSymCo co')  }
    go (TcNthCo n co)         = do { co' <- go co; return (mkTcNthCo n co')  }
    go (TcTransCo co1 co2)    = do { co1' <- go co1; co2' <- go co2
                                   ; return (mkTcTransCo co1' co2')  }
    go (TcForAllCo tv co)     = ASSERT( isImmutableTyVar tv )
                                do { co' <- go co; return (mkTcForAllCo tv co') }
    go (TcInstCo co ty)       = do { co' <- go co; ty' <- zonkTcTypeToType env ty; return (TcInstCo co' ty') }
\end{code}
