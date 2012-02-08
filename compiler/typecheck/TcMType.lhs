%
% (c) The University of Glasgow 2006
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%

Monadic type operations

This module contains monadic operations over types that contain
mutable type variables

\begin{code}
{-# OPTIONS -fno-warn-tabs #-}
-- The above warning supression flag is a temporary kludge.
-- While working on this module you are encouraged to remove it and
-- detab the module (please do the detabbing in a separate patch). See
--     http://hackage.haskell.org/trac/ghc/wiki/Commentary/CodingStyle#TabsvsSpaces
-- for details

module TcMType (
  TcTyVar, TcKind, TcType, TcTauType, TcThetaType, TcTyVarSet,

  --------------------------------
  -- Creating new mutable type variables
  newFlexiTyVar,
  newFlexiTyVarTy,		-- Kind -> TcM TcType
  newFlexiTyVarTys,		-- Int -> Kind -> TcM [TcType]
  newMetaKindVar, newMetaKindVars,
  mkTcTyVarName,

  newMetaTyVar, readMetaTyVar, writeMetaTyVar, writeMetaTyVarRef,
  isFilledMetaTyVar, isFlexiMetaTyVar,

  --------------------------------
  -- Creating new evidence variables
  newEvVar, newEvVars,
  newEq, newIP, newDict,

  newWantedEvVar, newWantedEvVars,
  newTcEvBinds, addTcEvBind,

  --------------------------------
  -- Instantiation
  tcInstTyVars, tcInstSigTyVars,
  tcInstType, 
  tcInstSkolTyVars, tcInstSuperSkolTyVars,
  tcInstSkolTyVarsX, tcInstSuperSkolTyVarsX,
  tcInstSkolTyVar, tcInstSkolType,
  tcSkolDFunType, tcSuperSkolTyVars,

  --------------------------------
  -- Checking type validity
  Rank, UserTypeCtxt(..), checkValidType, checkValidMonoType,
  expectedKindInCtxt, 
  checkValidTheta, 
  checkValidInstHead, checkValidInstance, validDerivPred,
  checkInstTermination, checkValidFamInst, checkTyFamFreeness, 
  arityErr, 
  growPredTyVars, growThetaTyVars, 

  --------------------------------
  -- Zonking
  zonkType, zonkKind, zonkTcPredType, zonkTyVarKind,
  zonkTcTypeCarefully, skolemiseUnboundMetaTyVar,
  zonkTcTyVar, zonkTcTyVars, zonkTcTyVarsAndFV, zonkSigTyVar,
  zonkQuantifiedTyVar, zonkQuantifiedTyVars,
  zonkTcType, zonkTcTypes, zonkTcThetaType,

  zonkTcKind, defaultKindVarToStar, zonkCt, zonkCts,
  zonkImplication, zonkEvVar, zonkWantedEvVar,

  zonkWC, zonkWantedEvVars,
  zonkTcTypeAndSubst,
  tcGetGlobalTyVars, 

  compatKindTcM, isSubKindTcM
  ) where

#include "HsVersions.h"

-- friends:
import TypeRep
import TcType
import Type
import Kind
import Class
import TyCon
import Var

-- others:
import HsSyn		-- HsType
import TcRnMonad        -- TcType, amongst others
import IParam
import Id
import FunDeps
import Name
import VarSet
import ErrUtils
import DynFlags
import Util
import Maybes
import ListSetOps
import BasicTypes
import SrcLoc
import Outputable
import FastString
import Unique( Unique )
import Bag

import Control.Monad
import Data.List        ( (\\), partition, mapAccumL )
\end{code}


%************************************************************************
%*									*
	Kind variables
%*									*
%************************************************************************

\begin{code}
newMetaKindVar :: TcM TcKind
newMetaKindVar = do	{ uniq <- newUnique
		; ref <- newMutVar Flexi
		; return (mkTyVarTy (mkMetaKindVar uniq ref)) }

newMetaKindVars :: Int -> TcM [TcKind]
newMetaKindVars n = mapM (\ _ -> newMetaKindVar) (nOfThem n ())
\end{code}


%************************************************************************
%*									*
     Evidence variables; range over constraints we can abstract over
%*									*
%************************************************************************

\begin{code}
newEvVars :: TcThetaType -> TcM [EvVar]
newEvVars theta = mapM newEvVar theta

newWantedEvVar :: TcPredType -> TcM EvVar 
newWantedEvVar = newEvVar

newWantedEvVars :: TcThetaType -> TcM [EvVar] 
newWantedEvVars theta = mapM newWantedEvVar theta 

--------------

newEvVar :: TcPredType -> TcM EvVar
-- Creates new *rigid* variables for predicates
newEvVar ty = do { name <- newName (predTypeOccName ty) 
                 ; return (mkLocalId name ty) }

newEq :: TcType -> TcType -> TcM EvVar
newEq ty1 ty2
  = do { name <- newName (mkVarOccFS (fsLit "cobox"))
       ; return (mkLocalId name (mkEqPred (ty1, ty2))) }

newIP :: IPName Name -> TcType -> TcM IpId
newIP ip ty
  = do 	{ name <- newName (mkVarOccFS (ipFastString ip))
        ; return (mkLocalId name (mkIPPred ip ty)) }

newDict :: Class -> [TcType] -> TcM DictId
newDict cls tys 
  = do { name <- newName (mkDictOcc (getOccName cls))
       ; return (mkLocalId name (mkClassPred cls tys)) }

predTypeOccName :: PredType -> OccName
predTypeOccName ty = case classifyPredType ty of
    ClassPred cls _ -> mkDictOcc (getOccName cls)
    IPPred ip _     -> mkVarOccFS (ipFastString ip)
    EqPred _ _      -> mkVarOccFS (fsLit "cobox")
    TuplePred _     -> mkVarOccFS (fsLit "tup")
    IrredPred _     -> mkVarOccFS (fsLit "irred")
\end{code}


%************************************************************************
%*									*
	SkolemTvs (immutable)
%*									*
%************************************************************************

\begin{code}
tcInstType :: ([TyVar] -> TcM [TcTyVar]) 		-- How to instantiate the type variables
	   -> TcType 					-- Type to instantiate
	   -> TcM ([TcTyVar], TcThetaType, TcType)	-- Result
		-- (type vars (excl coercion vars), preds (incl equalities), rho)
tcInstType inst_tyvars ty
  = case tcSplitForAllTys ty of
	([],     rho) -> let	-- There may be overloading despite no type variables;
				-- 	(?x :: Int) => Int -> Int
			   (theta, tau) = tcSplitPhiTy rho
			 in
			 return ([], theta, tau)

	(tyvars, rho) -> do { tyvars' <- inst_tyvars tyvars

			    ; let  tenv = zipTopTvSubst tyvars (mkTyVarTys tyvars')
				-- Either the tyvars are freshly made, by inst_tyvars,
                                -- or any nested foralls have different binders.
                                -- Either way, zipTopTvSubst is ok

			    ; let  (theta, tau) = tcSplitPhiTy (substTy tenv rho)
			    ; return (tyvars', theta, tau) }

tcSkolDFunType :: Type -> TcM ([TcTyVar], TcThetaType, TcType)
-- Instantiate a type signature with skolem constants, but 
-- do *not* give them fresh names, because we want the name to
-- be in the type environment: it is lexically scoped.
tcSkolDFunType ty = tcInstType (\tvs -> return (tcSuperSkolTyVars tvs)) ty

tcSuperSkolTyVars :: [TyVar] -> [TcTyVar]
-- Make skolem constants, but do *not* give them new names, as above
-- Moreover, make them "super skolems"; see comments with superSkolemTv
-- see Note [Kind substitution when instantiating]
-- Precondition: tyvars should be ordered (kind vars first)
tcSuperSkolTyVars = snd . mapAccumL tcSuperSkolTyVar (mkTopTvSubst [])

tcSuperSkolTyVar :: TvSubst -> TyVar -> (TvSubst, TcTyVar)
tcSuperSkolTyVar subst tv
  = (extendTvSubst subst tv (mkTyVarTy new_tv), new_tv)
  where
    kind   = substTy subst (tyVarKind tv)
    new_tv = mkTcTyVar (tyVarName tv) kind superSkolemTv

tcInstSkolTyVar :: Bool -> TvSubst -> TyVar -> TcM (TvSubst, TcTyVar)
-- Instantiate the tyvar, using 
--      * the occ-name and kind of the supplied tyvar, 
--      * the unique from the monad,
--      * the location either from the tyvar (skol_info = SigSkol)
--                     or from the monad (otherwise)
tcInstSkolTyVar overlappable subst tyvar
  = do  { uniq <- newUnique
        ; loc  <- getSrcSpanM
        ; let new_name = mkInternalName uniq occ loc
              new_tv   = mkTcTyVar new_name kind (SkolemTv overlappable)
        ; return (extendTvSubst subst tyvar (mkTyVarTy new_tv), new_tv) }
  where
    old_name = tyVarName tyvar
    occ      = nameOccName old_name
    kind     = substTy subst (tyVarKind tyvar)

tcInstSkolTyVars' :: Bool -> TvSubst -> [TyVar] -> TcM (TvSubst, [TcTyVar])
-- Precondition: tyvars should be ordered (kind vars first)
-- see Note [Kind substitution when instantiating]
tcInstSkolTyVars' isSuperSkol = mapAccumLM (tcInstSkolTyVar isSuperSkol)

-- Wrappers
tcInstSkolTyVars, tcInstSuperSkolTyVars :: [TyVar] -> TcM [TcTyVar]
tcInstSkolTyVars      = fmap snd . tcInstSkolTyVars' False (mkTopTvSubst [])
tcInstSuperSkolTyVars = fmap snd . tcInstSkolTyVars' True  (mkTopTvSubst [])

tcInstSkolTyVarsX, tcInstSuperSkolTyVarsX
  :: TvSubst -> [TyVar] -> TcM (TvSubst, [TcTyVar])
tcInstSkolTyVarsX      subst = tcInstSkolTyVars' False subst
tcInstSuperSkolTyVarsX subst = tcInstSkolTyVars' True  subst

tcInstSkolType :: TcType -> TcM ([TcTyVar], TcThetaType, TcType)
-- Instantiate a type with fresh skolem constants
-- Binding location comes from the monad
tcInstSkolType ty = tcInstType tcInstSkolTyVars ty

tcInstSigTyVars :: [TyVar] -> TcM [TcTyVar]
-- Make meta SigTv type variables for patten-bound scoped type varaibles
-- We use SigTvs for them, so that they can't unify with arbitrary types
-- Precondition: tyvars should be ordered (kind vars first)
-- see Note [Kind substitution when instantiating]
tcInstSigTyVars = fmap snd . mapAccumLM tcInstSigTyVar (mkTopTvSubst [])

tcInstSigTyVar :: TvSubst -> TyVar -> TcM (TvSubst, TcTyVar)
tcInstSigTyVar subst tv
  = do { uniq <- newMetaUnique
       ; ref <- newMutVar Flexi
       ; let name   = setNameUnique (tyVarName tv) uniq
                      -- Use the same OccName so that the tidy-er
                      -- doesn't rename 'a' to 'a0' etc
             kind   = substTy subst (tyVarKind tv)
             new_tv = mkTcTyVar name kind (MetaTv SigTv ref)
       ; return (extendTvSubst subst tv (mkTyVarTy new_tv), new_tv) }
\end{code}

Note [Kind substitution when instantiating]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
When we instantiate a bunch of kind and type variables, first we
expect them to be sorted (kind variables first, then type variables).
Then we have to instantiate the kind variables, build a substitution
from old variables to the new variables, then instantiate the type
variables substituting the original kind.

Exemple: If we want to instantiate
  [(k1 :: BOX), (k2 :: BOX), (a :: k1 -> k2), (b :: k1)]
we want
  [(?k1 :: BOX), (?k2 :: BOX), (?a :: ?k1 -> ?k2), (?b :: ?k1)]
instead of the buggous
  [(?k1 :: BOX), (?k2 :: BOX), (?a :: k1 -> k2), (?b :: k1)]


%************************************************************************
%*									*
	MetaTvs (meta type variables; mutable)
%*									*
%************************************************************************

\begin{code}
newMetaTyVar :: MetaInfo -> Kind -> TcM TcTyVar
-- Make a new meta tyvar out of thin air
newMetaTyVar meta_info kind
  = do	{ uniq <- newMetaUnique
 	; ref <- newMutVar Flexi
        ; let name = mkTcTyVarName uniq s
              s = case meta_info of
                        TauTv -> fsLit "t"
                        TcsTv -> fsLit "u"
                        SigTv -> fsLit "a"
	; return (mkTcTyVar name kind (MetaTv meta_info ref)) }

mkTcTyVarName :: Unique -> FastString -> Name
-- Make sure that fresh TcTyVar names finish with a digit
-- leaving the un-cluttered names free for user names
mkTcTyVarName uniq str = mkSysTvName uniq str

-- Works for both type and kind variables
readMetaTyVar :: TyVar -> TcM MetaDetails
readMetaTyVar tyvar = ASSERT2( isMetaTyVar tyvar, ppr tyvar )
		      readMutVar (metaTvRef tyvar)

isFilledMetaTyVar :: TyVar -> TcM Bool
-- True of a filled-in (Indirect) meta type variable
isFilledMetaTyVar tv
  | not (isTcTyVar tv) = return False
  | MetaTv _ ref <- tcTyVarDetails tv
  = do 	{ details <- readMutVar ref
	; return (isIndirect details) }
  | otherwise = return False

isFlexiMetaTyVar :: TyVar -> TcM Bool
-- True of a un-filled-in (Flexi) meta type variable
isFlexiMetaTyVar tv
  | not (isTcTyVar tv) = return False
  | MetaTv _ ref <- tcTyVarDetails tv
  = do 	{ details <- readMutVar ref
	; return (isFlexi details) }
  | otherwise = return False

--------------------
-- Works with both type and kind variables
writeMetaTyVar :: TcTyVar -> TcType -> TcM ()
-- Write into a currently-empty MetaTyVar

writeMetaTyVar tyvar ty
  | not debugIsOn 
  = writeMetaTyVarRef tyvar (metaTvRef tyvar) ty

-- Everything from here on only happens if DEBUG is on
  | not (isTcTyVar tyvar)
  = WARN( True, text "Writing to non-tc tyvar" <+> ppr tyvar )
    return ()

  | MetaTv _ ref <- tcTyVarDetails tyvar
  = writeMetaTyVarRef tyvar ref ty

  | otherwise
  = WARN( True, text "Writing to non-meta tyvar" <+> ppr tyvar )
    return ()

--------------------
writeMetaTyVarRef :: TcTyVar -> TcRef MetaDetails -> TcType -> TcM ()
-- Here the tyvar is for error checking only; 
-- the ref cell must be for the same tyvar
writeMetaTyVarRef tyvar ref ty
  | not debugIsOn 
  = do { traceTc "writeMetaTyVar" (ppr tyvar <+> text ":=" <+> ppr ty)
       ; writeMutVar ref (Indirect ty) }

-- Everything from here on only happens if DEBUG is on
  | otherwise
  = do { meta_details <- readMutVar ref; 
       -- Zonk kinds to allow the error check to work
       ; zonked_tv_kind <- zonkTcKind tv_kind 
       ; zonked_ty_kind <- zonkTcKind ty_kind

       -- Check for double updates
       ; ASSERT2( isFlexi meta_details, 
                  hang (text "Double update of meta tyvar")
                   2 (ppr tyvar $$ ppr meta_details) )

         traceTc "writeMetaTyVar" (ppr tyvar <+> text ":=" <+> ppr ty)
       ; writeMutVar ref (Indirect ty) 
       ; when (   not (isPredTy tv_kind) 
                    -- Don't check kinds for updates to coercion variables
               && not (zonked_ty_kind `isSubKind` zonked_tv_kind))
       $ WARN( True, hang (text "Ill-kinded update to meta tyvar")
                        2 (    ppr tyvar <+> text "::" <+> ppr tv_kind 
                           <+> text ":=" 
                           <+> ppr ty    <+> text "::" <+> ppr ty_kind) )
         (return ()) }
  where
    tv_kind = tyVarKind tyvar
    ty_kind = typeKind ty
\end{code}


%************************************************************************
%*									*
	MetaTvs: TauTvs
%*									*
%************************************************************************

\begin{code}
newFlexiTyVar :: Kind -> TcM TcTyVar
newFlexiTyVar kind = newMetaTyVar TauTv kind

newFlexiTyVarTy  :: Kind -> TcM TcType
newFlexiTyVarTy kind = do
    tc_tyvar <- newFlexiTyVar kind
    return (TyVarTy tc_tyvar)

newFlexiTyVarTys :: Int -> Kind -> TcM [TcType]
newFlexiTyVarTys n kind = mapM newFlexiTyVarTy (nOfThem n kind)

tcInstTyVars :: [TyVar] -> TcM ([TcTyVar], [TcType], TvSubst)
-- Instantiate with META type variables
tcInstTyVars tyvars = tcInstTyVarsX emptyTvSubst tyvars
    -- emptyTvSubst has an empty in-scope set, but that's fine here
    -- Since the tyvars are freshly made, they cannot possibly be
    -- captured by any existing for-alls.

tcInstTyVarsX :: TvSubst -> [TyVar] -> TcM ([TcTyVar], [TcType], TvSubst)
tcInstTyVarsX subst tyvars =
  do { (subst', tyvars') <- mapAccumLM tcInstTyVar subst tyvars
     ; return (tyvars', mkTyVarTys tyvars', subst') }

tcInstTyVar :: TvSubst -> TyVar -> TcM (TvSubst, TcTyVar)
-- Make a new unification variable tyvar whose Name and Kind come from
-- an existing TyVar. We substitute kind variables in the kind.
tcInstTyVar subst tyvar
  = do  { uniq <- newMetaUnique
        ; ref <- newMutVar Flexi
        ; let name   = mkSystemName uniq (getOccName tyvar)
              kind   = substTy subst (tyVarKind tyvar)
              new_tv = mkTcTyVar name kind (MetaTv TauTv ref)
        ; return (extendTvSubst subst tyvar (mkTyVarTy new_tv), new_tv) }
\end{code}


%************************************************************************
%*									*
	MetaTvs: SigTvs
%*									*
%************************************************************************

\begin{code}
zonkSigTyVar :: TcTyVar -> TcM TcTyVar
zonkSigTyVar sig_tv 
  | isSkolemTyVar sig_tv 
  = return sig_tv	-- Happens in the call in TcBinds.checkDistinctTyVars
  | otherwise
  = ASSERT( isSigTyVar sig_tv )
    do { ty <- zonkTcTyVar sig_tv
       ; return (tcGetTyVar "zonkSigTyVar" ty) }
	-- 'ty' is bound to be a type variable, because SigTvs
	-- can only be unified with type variables
\end{code}



%************************************************************************
%*									*
\subsection{Zonking -- the exernal interfaces}
%*									*
%************************************************************************

@tcGetGlobalTyVars@ returns a fully-zonked set of tyvars free in the environment.
To improve subsequent calls to the same function it writes the zonked set back into
the environment.

\begin{code}
tcGetGlobalTyVars :: TcM TcTyVarSet
tcGetGlobalTyVars
  = do { (TcLclEnv {tcl_tyvars = gtv_var}) <- getLclEnv
       ; gbl_tvs  <- readMutVar gtv_var
       ; gbl_tvs' <- zonkTcTyVarsAndFV gbl_tvs
       ; writeMutVar gtv_var gbl_tvs'
       ; return gbl_tvs' }
\end{code}

-----------------  Type variables

\begin{code}
zonkTcTyVars :: [TcTyVar] -> TcM [TcType]
zonkTcTyVars tyvars = mapM zonkTcTyVar tyvars

zonkTcTyVarsAndFV :: TcTyVarSet -> TcM TcTyVarSet
zonkTcTyVarsAndFV tyvars = tyVarsOfTypes <$> mapM zonkTcTyVar (varSetElems tyvars)

-----------------  Types
zonkTcTypeCarefully :: TcType -> TcM TcType
-- Do not zonk type variables free in the environment
zonkTcTypeCarefully ty = zonkTcType ty   -- I think this function is out of date

{-
  = do { env_tvs <- tcGetGlobalTyVars
       ; zonkType (zonk_tv env_tvs) ty }
  where
    zonk_tv env_tvs tv
      | tv `elemVarSet` env_tvs 
      = return (TyVarTy tv)
      | otherwise
      = ASSERT( isTcTyVar tv )
    	case tcTyVarDetails tv of
          SkolemTv {}   -> return (TyVarTy tv)
          RuntimeUnk {} -> return (TyVarTy tv)
          FlatSkol ty   -> zonkType (zonk_tv env_tvs) ty
          MetaTv _ ref  -> do { cts <- readMutVar ref
                              ; case cts of
			           Flexi       -> return (TyVarTy tv)
			           Indirect ty -> zonkType (zonk_tv env_tvs) ty }
-}

zonkTcType :: TcType -> TcM TcType
-- Simply look through all Flexis
zonkTcType ty = zonkType zonkTcTyVar ty

zonkTcTyVar :: TcTyVar -> TcM TcType
-- Simply look through all Flexis
zonkTcTyVar tv
  = ASSERT2( isTcTyVar tv, ppr tv ) do
    case tcTyVarDetails tv of
      SkolemTv {}   -> zonk_kind_and_return
      RuntimeUnk {} -> zonk_kind_and_return
      FlatSkol ty   -> zonkTcType ty
      MetaTv _ ref  -> do { cts <- readMutVar ref
                          ; case cts of
		               Flexi       -> zonk_kind_and_return
			       Indirect ty -> zonkTcType ty }
  where
    zonk_kind_and_return = do { z_tv <- zonkTyVarKind tv
                              ; return (TyVarTy z_tv) }

zonkTyVarKind :: TyVar -> TcM TyVar
zonkTyVarKind tv = do { kind' <- zonkTcKind (tyVarKind tv)
                      ; return (setTyVarKind tv kind') }

zonkTcTypeAndSubst :: TvSubst -> TcType -> TcM TcType
-- Zonk, and simultaneously apply a non-necessarily-idempotent substitution
zonkTcTypeAndSubst subst ty = zonkType zonk_tv ty
  where
    zonk_tv tv
      = do { z_tv <- updateTyVarKindM zonkTcKind tv
           ; case tcTyVarDetails tv of
                SkolemTv {}   -> return (TyVarTy z_tv)
                RuntimeUnk {} -> return (TyVarTy z_tv)
                FlatSkol ty   -> zonkType zonk_tv ty
                MetaTv _ ref  -> do { cts <- readMutVar ref
                                    ; case cts of
      			           Flexi       -> zonk_flexi z_tv
      			           Indirect ty -> zonkType zonk_tv ty } }
    zonk_flexi tv
      = case lookupTyVar subst tv of
          Just ty -> zonkType zonk_tv ty
          Nothing -> return (TyVarTy tv)

zonkTcTypes :: [TcType] -> TcM [TcType]
zonkTcTypes tys = mapM zonkTcType tys

zonkTcThetaType :: TcThetaType -> TcM TcThetaType
zonkTcThetaType theta = mapM zonkTcPredType theta

zonkTcPredType :: TcPredType -> TcM TcPredType
zonkTcPredType = zonkTcType
\end{code}

-------------------  These ...ToType, ...ToKind versions
		     are used at the end of type checking

\begin{code}
defaultKindVarToStar :: TcTyVar -> TcM Kind
-- We have a meta-kind: unify it with '*'
defaultKindVarToStar kv 
  = do { ASSERT ( isKiVar kv && isMetaTyVar kv )
         writeMetaTyVar kv liftedTypeKind
       ; return liftedTypeKind }

zonkQuantifiedTyVars :: TcTyVarSet -> TcM [TcTyVar]
-- Precondition: a kind variable occurs before a type
--               variable mentioning it in its kind
zonkQuantifiedTyVars tyvars
  = do { let (kvs, tvs) = partitionKiTyVars (varSetElems tyvars)
       ; poly_kinds <- xoptM Opt_PolyKinds
       ; if poly_kinds then
             mapM zonkQuantifiedTyVar (kvs ++ tvs)
           -- Because of the order, any kind variables
           -- mentioned in the kinds of the type variables refer to
           -- the now-quantified versions
         else
             -- In the non-PolyKinds case, default the kind variables
             -- to *, and zonk the tyvars as usual.  Notice that this
             -- may make zonkQuantifiedTyVars return a shorter list
             -- than it was passed, but that's ok
             do { let (meta_kvs, skolem_kvs) = partition isMetaTyVar kvs
                ; WARN ( not (null skolem_kvs), ppr skolem_kvs )
                  mapM_ defaultKindVarToStar meta_kvs
                ; mapM zonkQuantifiedTyVar (skolem_kvs ++ tvs) } }

zonkQuantifiedTyVar :: TcTyVar -> TcM TcTyVar
-- The quantified type variables often include meta type variables
-- we want to freeze them into ordinary type variables, and
-- default their kind (e.g. from OpenTypeKind to TypeKind)
-- 			-- see notes with Kind.defaultKind
-- The meta tyvar is updated to point to the new skolem TyVar.  Now any 
-- bound occurences of the original type variable will get zonked to 
-- the immutable version.
--
-- We leave skolem TyVars alone; they are immutable.
--
-- This function is called on both kind and type variables,
-- but kind variables *only* if PolyKinds is on.
zonkQuantifiedTyVar tv
  = ASSERT2( isTcTyVar tv, ppr tv ) 
    case tcTyVarDetails tv of
      SkolemTv {} -> do { kind <- zonkTcKind (tyVarKind tv)
                        ; return $ setTyVarKind tv kind }
	-- It might be a skolem type variable, 
	-- for example from a user type signature

      MetaTv _ ref ->
          do when debugIsOn $ do
                 -- [Sept 04] Check for non-empty.
                 -- See note [Silly Type Synonym]
                 cts <- readMutVar ref
                 case cts of
                     Flexi -> return ()
                     Indirect ty -> WARN( True, ppr tv $$ ppr ty )
                                    return ()
             skolemiseUnboundMetaTyVar tv vanillaSkolemTv
      _other -> pprPanic "zonkQuantifiedTyVar" (ppr tv) -- FlatSkol, RuntimeUnk

skolemiseUnboundMetaTyVar :: TcTyVar -> TcTyVarDetails -> TcM TyVar
-- We have a Meta tyvar with a ref-cell inside it
-- Skolemise it, including giving it a new Name, so that
--   we are totally out of Meta-tyvar-land
-- We create a skolem TyVar, not a regular TyVar
--   See Note [Zonking to Skolem]
skolemiseUnboundMetaTyVar tv details
  = ASSERT2( isMetaTyVar tv, ppr tv ) 
    do  { span <- getSrcSpanM    -- Get the location from "here"
                                 -- ie where we are generalising
        ; uniq <- newUnique      -- Remove it from TcMetaTyVar unique land
        ; kind <- zonkTcKind (tyVarKind tv)
        ; let final_kind = defaultKind kind
              final_name = mkInternalName uniq (getOccName tv) span
              final_tv   = mkTcTyVar final_name final_kind details

        ; writeMetaTyVar tv (mkTyVarTy final_tv)
        ; return final_tv }
\end{code}

\begin{code}
zonkImplication :: Implication -> TcM Implication
zonkImplication implic@(Implic { ic_given = given 
                               , ic_wanted = wanted
                               , ic_loc = loc })
  = do {    -- No need to zonk the skolems
       ; given'  <- mapM zonkEvVar given
       ; loc'    <- zonkGivenLoc loc
       ; wanted' <- zonkWC wanted
       ; return (implic { ic_given = given'
                        , ic_wanted = wanted'
                        , ic_loc = loc' }) }

zonkEvVar :: EvVar -> TcM EvVar
zonkEvVar var = do { ty' <- zonkTcType (varType var)
                   ; return (setVarType var ty') }


zonkWC :: WantedConstraints -> TcM WantedConstraints
zonkWC (WC { wc_flat = flat, wc_impl = implic, wc_insol = insol })
  = do { flat'   <- mapBagM zonkCt flat 
       ; implic' <- mapBagM zonkImplication implic
       ; insol'  <- mapBagM zonkCt insol
       ; return (WC { wc_flat = flat', wc_impl = implic', wc_insol = insol' }) }

zonkCt :: Ct -> TcM Ct 
-- Zonking a Ct conservatively gives back a CNonCanonical
zonkCt ct 
  = do { v'  <- zonkEvVar (cc_id ct)
       ; fl' <- zonkFlavor (cc_flavor ct)
       ; return $ 
         CNonCanonical { cc_id = v'
                       , cc_flavor = fl'
                       , cc_depth = cc_depth ct } }
zonkCts :: Cts -> TcM Cts
zonkCts = mapBagM zonkCt

zonkWantedEvVars :: Bag WantedEvVar -> TcM (Bag WantedEvVar)
zonkWantedEvVars = mapBagM zonkWantedEvVar

zonkWantedEvVar :: WantedEvVar -> TcM WantedEvVar
zonkWantedEvVar (EvVarX v l) = do { v' <- zonkEvVar v; return (EvVarX v' l) }

zonkFlavor :: CtFlavor -> TcM CtFlavor
zonkFlavor (Given loc gk) = do { loc' <- zonkGivenLoc loc; return (Given loc' gk) }
zonkFlavor fl             = return fl

zonkGivenLoc :: GivenLoc -> TcM GivenLoc
-- GivenLocs may have unification variables inside them!
zonkGivenLoc (CtLoc skol_info span ctxt)
  = do { skol_info' <- zonkSkolemInfo skol_info
       ; return (CtLoc skol_info' span ctxt) }

zonkSkolemInfo :: SkolemInfo -> TcM SkolemInfo
zonkSkolemInfo (SigSkol cx ty)  = do { ty' <- zonkTcType ty
                                     ; return (SigSkol cx ty') }
zonkSkolemInfo (InferSkol ntys) = do { ntys' <- mapM do_one ntys
                                     ; return (InferSkol ntys') }
  where
    do_one (n, ty) = do { ty' <- zonkTcType ty; return (n, ty') }
zonkSkolemInfo skol_info = return skol_info
\end{code}

Note [Silly Type Synonyms]
~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider this:
	type C u a = u	-- Note 'a' unused

	foo :: (forall a. C u a -> C u a) -> u
	foo x = ...

	bar :: Num u => u
	bar = foo (\t -> t + t)

* From the (\t -> t+t) we get type  {Num d} =>  d -> d
  where d is fresh.

* Now unify with type of foo's arg, and we get:
	{Num (C d a)} =>  C d a -> C d a
  where a is fresh.

* Now abstract over the 'a', but float out the Num (C d a) constraint
  because it does not 'really' mention a.  (see exactTyVarsOfType)
  The arg to foo becomes
	\/\a -> \t -> t+t

* So we get a dict binding for Num (C d a), which is zonked to give
	a = ()
  [Note Sept 04: now that we are zonking quantified type variables
  on construction, the 'a' will be frozen as a regular tyvar on
  quantification, so the floated dict will still have type (C d a).
  Which renders this whole note moot; happily!]

* Then the \/\a abstraction has a zonked 'a' in it.

All very silly.   I think its harmless to ignore the problem.  We'll end up with
a \/\a in the final result but all the occurrences of a will be zonked to ()

Note [Zonking to Skolem]
~~~~~~~~~~~~~~~~~~~~~~~~
We used to zonk quantified type variables to regular TyVars.  However, this
leads to problems.  Consider this program from the regression test suite:

  eval :: Int -> String -> String -> String
  eval 0 root actual = evalRHS 0 root actual

  evalRHS :: Int -> a
  evalRHS 0 root actual = eval 0 root actual

It leads to the deferral of an equality (wrapped in an implication constraint)

  forall a. () => ((String -> String -> String) ~ a)

which is propagated up to the toplevel (see TcSimplify.tcSimplifyInferCheck).
In the meantime `a' is zonked and quantified to form `evalRHS's signature.
This has the *side effect* of also zonking the `a' in the deferred equality
(which at this point is being handed around wrapped in an implication
constraint).

Finally, the equality (with the zonked `a') will be handed back to the
simplifier by TcRnDriver.tcRnSrcDecls calling TcSimplify.tcSimplifyTop.
If we zonk `a' with a regular type variable, we will have this regular type
variable now floating around in the simplifier, which in many places assumes to
only see proper TcTyVars.

We can avoid this problem by zonking with a skolem.  The skolem is rigid
(which we require for a quantified variable), but is still a TcTyVar that the
simplifier knows how to deal with.


%************************************************************************
%*									*
\subsection{Zonking -- the main work-horses: zonkType, zonkTyVar}
%*									*
%*		For internal use only!					*
%*									*
%************************************************************************

\begin{code}
-- For unbound, mutable tyvars, zonkType uses the function given to it
-- For tyvars bound at a for-all, zonkType zonks them to an immutable
--	type variable and zonks the kind too

zonkKind :: (TcTyVar -> TcM Kind) -> TcKind -> TcM Kind
zonkKind = zonkType

zonkType :: (TcTyVar -> TcM Type)  -- What to do with TcTyVars
         -> TcType -> TcM Type
zonkType zonk_tc_tyvar ty
  = go ty
  where
    go (TyConApp tc tys) = do tys' <- mapM go tys
                              return (TyConApp tc tys')

    go (FunTy arg res)   = do arg' <- go arg
                              res' <- go res
                              return (FunTy arg' res')

    go (AppTy fun arg)   = do fun' <- go fun
                              arg' <- go arg
                              return (mkAppTy fun' arg')
		-- NB the mkAppTy; we might have instantiated a
		-- type variable to a type constructor, so we need
		-- to pull the TyConApp to the top.

	-- The two interesting cases!
    go (TyVarTy tyvar) | isTcTyVar tyvar = zonk_tc_tyvar tyvar
		       | otherwise	 = TyVarTy <$> updateTyVarKindM zonkTcKind tyvar
		-- Ordinary (non Tc) tyvars occur inside quantified types

    go (ForAllTy tyvar ty) = ASSERT( isImmutableTyVar tyvar ) do
                             ty' <- go ty
                             tyvar' <- updateTyVarKindM zonkTcKind tyvar
                             return (ForAllTy tyvar' ty')
\end{code}



%************************************************************************
%*									*
			Zonking kinds
%*									*
%************************************************************************

\begin{code}
compatKindTcM :: Kind -> Kind -> TcM Bool
compatKindTcM k1 k2
  = do { k1' <- zonkTcKind k1
       ; k2' <- zonkTcKind k2
       ; return $ k1' `isSubKind` k2' || k2' `isSubKind` k1' }

isSubKindTcM :: Kind -> Kind -> TcM Bool
isSubKindTcM k1 k2
  = do { k1' <- zonkTcKind k1
       ; k2' <- zonkTcKind k2
       ; return $ k1' `isSubKind` k2' }

-------------
zonkTcKind :: TcKind -> TcM TcKind
zonkTcKind k = zonkTcType k
\end{code}
			
%************************************************************************
%*									*
\subsection{Checking a user type}
%*									*
%************************************************************************

When dealing with a user-written type, we first translate it from an HsType
to a Type, performing kind checking, and then check various things that should 
be true about it.  We don't want to perform these checks at the same time
as the initial translation because (a) they are unnecessary for interface-file
types and (b) when checking a mutually recursive group of type and class decls,
we can't "look" at the tycons/classes yet.  Also, the checks are are rather
diverse, and used to really mess up the other code.

One thing we check for is 'rank'.  

	Rank 0: 	monotypes (no foralls)
	Rank 1:		foralls at the front only, Rank 0 inside
	Rank 2:		foralls at the front, Rank 1 on left of fn arrow,

	basic ::= tyvar | T basic ... basic

	r2  ::= forall tvs. cxt => r2a
	r2a ::= r1 -> r2a | basic
	r1  ::= forall tvs. cxt => r0
	r0  ::= r0 -> r0 | basic
	
Another thing is to check that type synonyms are saturated. 
This might not necessarily show up in kind checking.
	type A i = i
	data T k = MkT (k Int)
	f :: T A	-- BAD!

	
\begin{code}
-- Depending on the context, we might accept any kind (for instance, in a TH
-- splice), or only certain kinds (like in type signatures).
expectedKindInCtxt :: UserTypeCtxt -> Maybe Kind
expectedKindInCtxt (TySynCtxt _)  = Nothing -- Any kind will do
expectedKindInCtxt ThBrackCtxt    = Nothing
expectedKindInCtxt GhciCtxt       = Nothing
expectedKindInCtxt ResSigCtxt     = Just openTypeKind
expectedKindInCtxt ExprSigCtxt    = Just openTypeKind
expectedKindInCtxt (ForSigCtxt _) = Just liftedTypeKind
expectedKindInCtxt _              = Just argTypeKind

checkValidType :: UserTypeCtxt -> Type -> TcM ()
-- Checks that the type is valid for the given context
checkValidType ctxt ty = do
    traceTc "checkValidType" (ppr ty <+> text "::" <+> ppr (typeKind ty))
    unboxed         <- xoptM Opt_UnboxedTuples
    rank2           <- xoptM Opt_Rank2Types
    rankn           <- xoptM Opt_RankNTypes
    polycomp        <- xoptM Opt_PolymorphicComponents
    constraintKinds <- xoptM Opt_ConstraintKinds
    let 
	gen_rank n | rankn     = ArbitraryRank
	           | rank2     = Rank 2
	           | otherwise = Rank n
	rank
	  = case ctxt of
		 DefaultDeclCtxt-> MustBeMonoType
		 ResSigCtxt	-> MustBeMonoType
		 LamPatSigCtxt	-> gen_rank 0
		 BindPatSigCtxt	-> gen_rank 0
		 TySynCtxt _    -> gen_rank 0

		 ExprSigCtxt 	-> gen_rank 1
		 FunSigCtxt _   -> gen_rank 1
		 InfSigCtxt _   -> ArbitraryRank	-- Inferred type
		 ConArgCtxt _   | polycomp -> gen_rank 2
                                -- We are given the type of the entire
                                -- constructor, hence rank 1
 				| otherwise -> gen_rank 1

		 ForSigCtxt _	-> gen_rank 1
		 SpecInstCtxt   -> gen_rank 1
                 ThBrackCtxt    -> gen_rank 1
		 GhciCtxt       -> ArbitraryRank
                 _              -> panic "checkValidType"
                                     -- Can't happen; not used for *user* sigs

	actual_kind = typeKind ty

        kind_ok = case expectedKindInCtxt ctxt of
                    Nothing -> True
                    Just k  -> tcIsSubKind actual_kind k
	
	ubx_tup 
         | not unboxed = UT_NotOk
         | otherwise   = case ctxt of
	              	   TySynCtxt _ -> UT_Ok
	              	   ExprSigCtxt -> UT_Ok
	              	   ThBrackCtxt -> UT_Ok
		      	   GhciCtxt    -> UT_Ok
	              	   _           -> UT_NotOk

	-- Check the internal validity of the type itself
    check_type rank ubx_tup ty

	-- Check that the thing has kind Type, and is lifted if necessary
	-- Do this second, because we can't usefully take the kind of an 
	-- ill-formed type such as (a~Int)
    checkTc kind_ok (kindErr actual_kind)

        -- Check that the thing does not have kind Constraint,
        -- if -XConstraintKinds isn't enabled
    unless constraintKinds
      $ checkTc (not (isConstraintKind actual_kind)) (predTupleErr ty)

checkValidMonoType :: Type -> TcM ()
checkValidMonoType ty = check_mono_type MustBeMonoType ty
\end{code}


\begin{code}
data Rank = ArbitraryRank	  -- Any rank ok
          | MustBeMonoType  	  -- Monotype regardless of flags
	  | TyConArgMonoType	  -- Monotype but could be poly if -XImpredicativeTypes
	  | SynArgMonoType	  -- Monotype but could be poly if -XLiberalTypeSynonyms
          | Rank Int		  -- Rank n, but could be more with -XRankNTypes

decRank :: Rank -> Rank		  -- Function arguments
decRank (Rank 0)   = Rank 0
decRank (Rank n)   = Rank (n-1)
decRank other_rank = other_rank

nonZeroRank :: Rank -> Bool
nonZeroRank ArbitraryRank = True
nonZeroRank (Rank n) 	  = n>0
nonZeroRank _        	  = False

----------------------------------------
data UbxTupFlag = UT_Ok	| UT_NotOk
	-- The "Ok" version means "ok if UnboxedTuples is on"

----------------------------------------
check_mono_type :: Rank -> KindOrType -> TcM ()	-- No foralls anywhere
				      		-- No unlifted types of any kind
check_mono_type rank ty
  | isKind ty = return ()  -- IA0_NOTE: Do we need to check kinds?
  | otherwise
   = do { check_type rank UT_NotOk ty
	; checkTc (not (isUnLiftedType ty)) (unliftedArgErr ty) }

check_type :: Rank -> UbxTupFlag -> Type -> TcM ()
-- The args say what the *type context* requires, independent
-- of *flag* settings.  You test the flag settings at usage sites.
-- 
-- Rank is allowed rank for function args
-- Rank 0 means no for-alls anywhere

check_type rank ubx_tup ty
  | not (null tvs && null theta)
  = do	{ checkTc (nonZeroRank rank) (forAllTyErr rank ty)
		-- Reject e.g. (Maybe (?x::Int => Int)), 
		-- with a decent error message
	; check_valid_theta SigmaCtxt theta
	; check_type rank ubx_tup tau	-- Allow foralls to right of arrow
	; checkAmbiguity tvs theta (tyVarsOfType tau) }
  where
    (tvs, theta, tau) = tcSplitSigmaTy ty
   
check_type _ _ (TyVarTy _) = return ()

check_type rank _ (FunTy arg_ty res_ty)
  = do	{ check_type (decRank rank) UT_NotOk arg_ty
	; check_type rank 	    UT_Ok    res_ty }

check_type rank _ (AppTy ty1 ty2)
  = do	{ check_arg_type rank ty1
	; check_arg_type rank ty2 }

check_type rank ubx_tup ty@(TyConApp tc tys)
  | isSynTyCon tc
  = do	{ 	-- Check that the synonym has enough args
		-- This applies equally to open and closed synonyms
	 	-- It's OK to have an *over-applied* type synonym
		--	data Tree a b = ...
		--	type Foo a = Tree [a]
		--	f :: Foo a b -> ...
 	  checkTc (tyConArity tc <= length tys) arity_msg

	-- See Note [Liberal type synonyms]
	; liberal <- xoptM Opt_LiberalTypeSynonyms
	; if not liberal || isSynFamilyTyCon tc then
		-- For H98 and synonym families, do check the type args
		mapM_ (check_mono_type SynArgMonoType) tys

	  else	-- In the liberal case (only for closed syns), expand then check
	  case tcView ty of   
	     Just ty' -> check_type rank ubx_tup ty' 
	     Nothing  -> pprPanic "check_tau_type" (ppr ty)
    }
    
  | isUnboxedTupleTyCon tc
  = do	{ ub_tuples_allowed <- xoptM Opt_UnboxedTuples
	; checkTc (ubx_tup_ok ub_tuples_allowed) ubx_tup_msg

	; impred <- xoptM Opt_ImpredicativeTypes	
	; let rank' = if impred then ArbitraryRank else TyConArgMonoType
		-- c.f. check_arg_type
		-- However, args are allowed to be unlifted, or
		-- more unboxed tuples, so can't use check_arg_ty
	; mapM_ (check_type rank' UT_Ok) tys }

  | otherwise
  = mapM_ (check_arg_type rank) tys

  where
    ubx_tup_ok ub_tuples_allowed = case ubx_tup of
                                   UT_Ok -> ub_tuples_allowed
                                   _     -> False

    n_args    = length tys
    tc_arity  = tyConArity tc

    arity_msg   = arityErr "Type synonym" (tyConName tc) tc_arity n_args
    ubx_tup_msg = ubxArgTyErr ty

check_type _ _ ty = pprPanic "check_type" (ppr ty)

----------------------------------------
check_arg_type :: Rank -> KindOrType -> TcM ()
-- The sort of type that can instantiate a type variable,
-- or be the argument of a type constructor.
-- Not an unboxed tuple, but now *can* be a forall (since impredicativity)
-- Other unboxed types are very occasionally allowed as type
-- arguments depending on the kind of the type constructor
-- 
-- For example, we want to reject things like:
--
--	instance Ord a => Ord (forall s. T s a)
-- and
--	g :: T s (forall b.b)
--
-- NB: unboxed tuples can have polymorphic or unboxed args.
--     This happens in the workers for functions returning
--     product types with polymorphic components.
--     But not in user code.
-- Anyway, they are dealt with by a special case in check_tau_type

check_arg_type rank ty
  | isKind ty = return ()  -- IA0_NOTE: Do we need to check a kind?
  | otherwise
  = do	{ impred <- xoptM Opt_ImpredicativeTypes
	; let rank' = case rank of 	    -- Predictive => must be monotype
	      	        MustBeMonoType     -> MustBeMonoType  -- Monotype, regardless
			_other | impred    -> ArbitraryRank
			       | otherwise -> TyConArgMonoType
			-- Make sure that MustBeMonoType is propagated, 
			-- so that we don't suggest -XImpredicativeTypes in
			--    (Ord (forall a.a)) => a -> a
			-- and so that if it Must be a monotype, we check that it is!

	; check_type rank' UT_NotOk ty
	; checkTc (not (isUnLiftedType ty)) (unliftedArgErr ty) }
             -- NB the isUnLiftedType test also checks for 
             --    T State#
             -- where there is an illegal partial application of State# (which has
             -- kind * -> #); see Note [The kind invariant] in TypeRep

----------------------------------------
forAllTyErr :: Rank -> Type -> SDoc
forAllTyErr rank ty 
   = vcat [ hang (ptext (sLit "Illegal polymorphic or qualified type:")) 2 (ppr ty)
          , suggestion ]
  where
    suggestion = case rank of
    	       	   Rank _ -> ptext (sLit "Perhaps you intended to use -XRankNTypes or -XRank2Types")
    	       	   TyConArgMonoType -> ptext (sLit "Perhaps you intended to use -XImpredicativeTypes")
    	       	   SynArgMonoType -> ptext (sLit "Perhaps you intended to use -XLiberalTypeSynonyms")
		   _ -> empty      -- Polytype is always illegal

unliftedArgErr, ubxArgTyErr :: Type -> SDoc
unliftedArgErr  ty = sep [ptext (sLit "Illegal unlifted type:"), ppr ty]
ubxArgTyErr     ty = sep [ptext (sLit "Illegal unboxed tuple type as function argument:"), ppr ty]

kindErr :: Kind -> SDoc
kindErr kind       = sep [ptext (sLit "Expecting an ordinary type, but found a type of kind"), ppr kind]
\end{code}

Note [Liberal type synonyms]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~
If -XLiberalTypeSynonyms is on, expand closed type synonyms *before*
doing validity checking.  This allows us to instantiate a synonym defn
with a for-all type, or with a partially-applied type synonym.
	e.g.   type T a b = a
	       type S m   = m ()
	       f :: S (T Int)
Here, T is partially applied, so it's illegal in H98.  But if you
expand S first, then T we get just
	       f :: Int
which is fine.

IMPORTANT: suppose T is a type synonym.  Then we must do validity
checking on an appliation (T ty1 ty2)

	*either* before expansion (i.e. check ty1, ty2)
	*or* after expansion (i.e. expand T ty1 ty2, and then check)
	BUT NOT BOTH

If we do both, we get exponential behaviour!!

  data TIACons1 i r c = c i ::: r c
  type TIACons2 t x = TIACons1 t (TIACons1 t x)
  type TIACons3 t x = TIACons2 t (TIACons1 t x)
  type TIACons4 t x = TIACons2 t (TIACons2 t x)
  type TIACons7 t x = TIACons4 t (TIACons3 t x)


%************************************************************************
%*									*
\subsection{Checking a theta or source type}
%*									*
%************************************************************************

\begin{code}
checkValidTheta :: UserTypeCtxt -> ThetaType -> TcM ()
checkValidTheta ctxt theta 
  = addErrCtxt (checkThetaCtxt ctxt theta) (check_valid_theta ctxt theta)

-------------------------
check_valid_theta :: UserTypeCtxt -> [PredType] -> TcM ()
check_valid_theta _ []
  = return ()
check_valid_theta ctxt theta = do
    dflags <- getDOpts
    warnTc (notNull dups) (dupPredWarn dups)
    mapM_ (check_pred_ty dflags ctxt) theta
  where
    (_,dups) = removeDups cmpPred theta

-------------------------
check_pred_ty :: DynFlags -> UserTypeCtxt -> PredType -> TcM ()
check_pred_ty dflags ctxt pred = check_pred_ty' dflags ctxt (shallowPredTypePredTree pred)

check_pred_ty' :: DynFlags -> UserTypeCtxt -> PredTree -> TcM ()
check_pred_ty' dflags ctxt (ClassPred cls tys)
  = do {	-- Class predicates are valid in all contexts
       ; checkTc (arity == n_tys) arity_err

		-- Check the form of the argument types
       ; mapM_ checkValidMonoType tys
       ; checkTc (check_class_pred_tys dflags ctxt tys)
		 (predTyVarErr (mkClassPred cls tys) $$ how_to_allow)
       }
  where
    class_name = className cls
    arity      = classArity cls
    n_tys      = length tys
    arity_err  = arityErr "Class" class_name arity n_tys
    how_to_allow = parens (ptext (sLit "Use -XFlexibleContexts to permit this"))


check_pred_ty' dflags _ctxt (EqPred ty1 ty2)
  = do {	-- Equational constraints are valid in all contexts if type
		-- families are permitted
       ; checkTc (xopt Opt_TypeFamilies dflags || xopt Opt_GADTs dflags) 
                 (eqPredTyErr (mkEqPred (ty1, ty2)))

		-- Check the form of the argument types
       ; checkValidMonoType ty1
       ; checkValidMonoType ty2
       }

check_pred_ty' _ _ctxt (IPPred _ ty) = checkValidMonoType ty
	-- Contrary to GHC 7.2 and below, we allow implicit parameters not only
	-- in type signatures but also in instance decls, superclasses etc
	-- The reason we didn't allow implicit params in instances is a bit
	-- subtle:
	-- If we allowed	instance (?x::Int, Eq a) => Foo [a] where ...
	-- then when we saw (e :: (?x::Int) => t) it would be unclear how to 
	-- discharge all the potential usas of the ?x in e.   For example, a
	-- constraint Foo [Int] might come out of e,and applying the
	-- instance decl would show up two uses of ?x.
        --
        -- Happily this is not an issue in the new constraint solver.

check_pred_ty' dflags ctxt t@(TuplePred ts)
  = do { checkTc (xopt Opt_ConstraintKinds dflags)
                 (predTupleErr (predTreePredType t))
       ; mapM_ (check_pred_ty dflags ctxt) ts }
    -- This case will not normally be executed because without -XConstraintKinds
    -- tuple types are only kind-checked as *

check_pred_ty' dflags ctxt (IrredPred pred)
    -- Allowing irreducible predicates in class superclasses is somewhat dangerous
    -- because we can write:
    --
    --  type family Fooish x :: * -> Constraint
    --  type instance Fooish () = Foo
    --  class Fooish () a => Foo a where
    --
    -- This will cause the constraint simplifier to loop because every time we canonicalise a
    -- (Foo a) class constraint we add a (Fooish () a) constraint which will be immediately
    -- solved to add+canonicalise another (Foo a) constraint.
    --
    -- It is equally dangerous to allow them in instance heads because in that case the
    -- Paterson conditions may not detect duplication of a type variable or size change.
    --
    -- In both cases it's OK if the predicate is actually a synonym, though.
    -- We'll also allow it if
  = do checkTc (xopt Opt_ConstraintKinds dflags)
               (predIrredErr pred)
       case tcView pred of
         Just pred' -> 
           -- Synonym: just look through
           check_pred_ty dflags ctxt pred'
         Nothing
           | xopt Opt_UndecidableInstances dflags -> return ()
           | otherwise -> do
             -- Make sure it is OK to have an irred pred in this context
             checkTc (case ctxt of ClassSCCtxt _ -> False; InstDeclCtxt -> False; _ -> True)
                     (predIrredBadCtxtErr pred)

-------------------------
check_class_pred_tys :: DynFlags -> UserTypeCtxt -> [KindOrType] -> Bool
check_class_pred_tys dflags ctxt kts
  = case ctxt of
	SpecInstCtxt -> True	-- {-# SPECIALISE instance Eq (T Int) #-} is fine
	InstDeclCtxt -> flexible_contexts || undecidable_ok || all tcIsTyVarTy tys
				-- Further checks on head and theta in
				-- checkInstTermination
	_             -> flexible_contexts || all tyvar_head tys
  where
    (_, tys) = span isKind kts  -- see Note [Kind polymorphic type classes]
    flexible_contexts = xopt Opt_FlexibleContexts dflags
    undecidable_ok = xopt Opt_UndecidableInstances dflags

{-
Note [Kind polymorphic type classes]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

class C f where
  empty :: f a
-- C :: forall k. k -> Constraint
-- empty :: forall (a :: k). f a

MultiParam:
~~~~~~~~~~~

instance C Maybe where
  empty = Nothing

The dictionary gets type [C * Maybe] even if it's not a MultiParam
type class.

Flexible:
~~~~~~~~~

data D a = D
-- D :: forall k. k -> *

instance C D where
  empty = D

The dictionary gets type [C * (D *)]. IA0_TODO it should be
generalized actually.

-}

-------------------------
tyvar_head :: Type -> Bool
tyvar_head ty			-- Haskell 98 allows predicates of form 
  | tcIsTyVarTy ty = True	-- 	C (a ty1 .. tyn)
  | otherwise			-- where a is a type variable
  = case tcSplitAppTy_maybe ty of
	Just (ty, _) -> tyvar_head ty
	Nothing	     -> False
\end{code}

Check for ambiguity
~~~~~~~~~~~~~~~~~~~
	  forall V. P => tau
is ambiguous if P contains generic variables
(i.e. one of the Vs) that are not mentioned in tau

However, we need to take account of functional dependencies
when we speak of 'mentioned in tau'.  Example:
	class C a b | a -> b where ...
Then the type
	forall x y. (C x y) => x
is not ambiguous because x is mentioned and x determines y

NB; the ambiguity check is only used for *user* types, not for types
coming from inteface files.  The latter can legitimately have
ambiguous types. Example

   class S a where s :: a -> (Int,Int)
   instance S Char where s _ = (1,1)
   f:: S a => [a] -> Int -> (Int,Int)
   f (_::[a]) x = (a*x,b)
	where (a,b) = s (undefined::a)

Here the worker for f gets the type
	fw :: forall a. S a => Int -> (# Int, Int #)

If the list of tv_names is empty, we have a monotype, and then we
don't need to check for ambiguity either, because the test can't fail
(see is_ambig).

In addition, GHC insists that at least one type variable
in each constraint is in V.  So we disallow a type like
	forall a. Eq b => b -> b
even in a scope where b is in scope.

\begin{code}
checkAmbiguity :: [TyVar] -> ThetaType -> TyVarSet -> TcM ()
checkAmbiguity forall_tyvars theta tau_tyvars
  = mapM_ complain (filter is_ambig theta)
  where
    complain pred     = addErrTc (ambigErr pred)
    extended_tau_vars = growThetaTyVars theta tau_tyvars

	-- See Note [Implicit parameters and ambiguity] in TcSimplify
    is_ambig pred     = isClassPred  pred &&
			any ambig_var (varSetElems (tyVarsOfType pred))

    ambig_var ct_var  = (ct_var `elem` forall_tyvars) &&
		        not (ct_var `elemVarSet` extended_tau_vars)

ambigErr :: PredType -> SDoc
ambigErr pred
  = sep [ptext (sLit "Ambiguous constraint") <+> quotes (pprType pred),
	 nest 2 (ptext (sLit "At least one of the forall'd type variables mentioned by the constraint") $$
		 ptext (sLit "must be reachable from the type after the '=>'"))]
\end{code}

Note [Growing the tau-tvs using constraints]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
(growInstsTyVars insts tvs) is the result of extending the set 
    of tyvars tvs using all conceivable links from pred

E.g. tvs = {a}, preds = {H [a] b, K (b,Int) c, Eq e}
Then grow precs tvs = {a,b,c}

\begin{code}
growThetaTyVars :: TcThetaType -> TyVarSet -> TyVarSet
-- See Note [Growing the tau-tvs using constraints]
growThetaTyVars theta tvs
  | null theta = tvs
  | otherwise  = fixVarSet mk_next tvs
  where
    mk_next tvs = foldr grow_one tvs theta
    grow_one pred tvs = growPredTyVars pred tvs `unionVarSet` tvs

growPredTyVars :: TcPredType
               -> TyVarSet	-- The set to extend
	       -> TyVarSet	-- TyVars of the predicate if it intersects
	       	  		-- the set, or is implicit parameter
growPredTyVars pred tvs = go (classifyPredType pred)
  where
    grow pred_tvs | pred_tvs `intersectsVarSet` tvs = pred_tvs
                  | otherwise                       = emptyVarSet

    go (IPPred _ ty)     = tyVarsOfType ty -- See Note [Implicit parameters and ambiguity]
    go (ClassPred _ tys) = grow (tyVarsOfTypes tys)
    go (EqPred ty1 ty2)  = grow (tyVarsOfType ty1 `unionVarSet` tyVarsOfType ty2)
    go (TuplePred ts)    = unionVarSets (map (go . classifyPredType) ts)
    go (IrredPred ty)    = grow (tyVarsOfType ty)
\end{code}
    
Note [Implicit parameters and ambiguity] 
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Only a *class* predicate can give rise to ambiguity
An *implicit parameter* cannot.  For example:
	foo :: (?x :: [a]) => Int
	foo = length ?x
is fine.  The call site will suppply a particular 'x'

Furthermore, the type variables fixed by an implicit parameter
propagate to the others.  E.g.
	foo :: (Show a, ?x::[a]) => Int
	foo = show (?x++?x)
The type of foo looks ambiguous.  But it isn't, because at a call site
we might have
	let ?x = 5::Int in foo
and all is well.  In effect, implicit parameters are, well, parameters,
so we can take their type variables into account as part of the
"tau-tvs" stuff.  This is done in the function 'FunDeps.grow'.


\begin{code}
checkThetaCtxt :: UserTypeCtxt -> ThetaType -> SDoc
checkThetaCtxt ctxt theta
  = vcat [ptext (sLit "In the context:") <+> pprTheta theta,
	  ptext (sLit "While checking") <+> pprUserTypeCtxt ctxt ]

eqPredTyErr, predTyVarErr, predTupleErr, predIrredErr, predIrredBadCtxtErr :: PredType -> SDoc
eqPredTyErr  pred = ptext (sLit "Illegal equational constraint") <+> pprType pred
		    $$
		    parens (ptext (sLit "Use -XGADTs or -XTypeFamilies to permit this"))
predTyVarErr pred  = sep [ptext (sLit "Non type-variable argument"),
			  nest 2 (ptext (sLit "in the constraint:") <+> pprType pred)]
predTupleErr pred  = ptext (sLit "Illegal tuple constraint") <+> pprType pred $$
                     parens (ptext (sLit "Use -XConstraintKinds to permit this"))
predIrredErr pred  = ptext (sLit "Illegal irreducible constraint") <+> pprType pred $$
                     parens (ptext (sLit "Use -XConstraintKinds to permit this"))
predIrredBadCtxtErr pred = ptext (sLit "Illegal irreducible constraint") <+> pprType pred $$
                           ptext (sLit "in superclass/instance head context") <+>
                           parens (ptext (sLit "Use -XUndecidableInstances to permit this"))
dupPredWarn :: [[PredType]] -> SDoc
dupPredWarn dups   = ptext (sLit "Duplicate constraint(s):") <+> pprWithCommas pprType (map head dups)

arityErr :: Outputable a => String -> a -> Int -> Int -> SDoc
arityErr kind name n m
  = hsep [ text kind, quotes (ppr name), ptext (sLit "should have"),
	   n_arguments <> comma, text "but has been given", 
           if m==0 then text "none" else int m]
    where
	n_arguments | n == 0 = ptext (sLit "no arguments")
		    | n == 1 = ptext (sLit "1 argument")
		    | True   = hsep [int n, ptext (sLit "arguments")]
\end{code}

%************************************************************************
%*									*
\subsection{Checking for a decent instance head type}
%*									*
%************************************************************************

@checkValidInstHead@ checks the type {\em and} its syntactic constraints:
it must normally look like: @instance Foo (Tycon a b c ...) ...@

The exceptions to this syntactic checking: (1)~if the @GlasgowExts@
flag is on, or (2)~the instance is imported (they must have been
compiled elsewhere). In these cases, we let them go through anyway.

We can also have instances for functions: @instance Foo (a -> b) ...@.

\begin{code}
checkValidInstHead :: UserTypeCtxt -> Class -> [Type] -> TcM ()
checkValidInstHead ctxt clas tys
  = do { dflags <- getDOpts

           -- Check language restrictions; 
           -- but not for SPECIALISE isntance pragmas
       ; unless spec_inst_prag $
         do { checkTc (xopt Opt_TypeSynonymInstances dflags ||
                       all tcInstHeadTyNotSynonym tys)
                 (instTypeErr pp_pred head_type_synonym_msg)
            ; checkTc (xopt Opt_FlexibleInstances dflags ||
                       all tcInstHeadTyAppAllTyVars tys)
                 (instTypeErr pp_pred head_type_args_tyvars_msg)
            ; checkTc (xopt Opt_MultiParamTypeClasses dflags ||
                       isSingleton (dropWhile isKind tys))  -- IA0_NOTE: only count type arguments
                 (instTypeErr pp_pred head_one_type_msg) }

         -- May not contain type family applications
       ; mapM_ checkTyFamFreeness tys

       ; mapM_ checkValidMonoType tys
	-- For now, I only allow tau-types (not polytypes) in 
	-- the head of an instance decl.  
	-- 	E.g.  instance C (forall a. a->a) is rejected
	-- One could imagine generalising that, but I'm not sure
	-- what all the consequences might be
       }

  where
    spec_inst_prag = case ctxt of { SpecInstCtxt -> True; _ -> False }

    pp_pred = pprClassPred clas tys
    head_type_synonym_msg = parens (
                text "All instance types must be of the form (T t1 ... tn)" $$
                text "where T is not a synonym." $$
                text "Use -XTypeSynonymInstances if you want to disable this.")

    head_type_args_tyvars_msg = parens (vcat [
                text "All instance types must be of the form (T a1 ... an)",
                text "where a1 ... an are *distinct type variables*,",
                text "and each type variable appears at most once in the instance head.",
                text "Use -XFlexibleInstances if you want to disable this."])

    head_one_type_msg = parens (
                text "Only one type can be given in an instance head." $$
                text "Use -XMultiParamTypeClasses if you want to allow more.")

instTypeErr :: SDoc -> SDoc -> SDoc
instTypeErr pp_ty msg
  = sep [ptext (sLit "Illegal instance declaration for") <+> quotes pp_ty, 
	 nest 2 msg]
\end{code}

validDeivPred checks for OK 'deriving' context.  See Note [Exotic
derived instance contexts] in TcSimplify.  However the predicate is
here because it uses sizeTypes, fvTypes.

Also check for a bizarre corner case, when the derived instance decl 
would look like
    instance C a b => D (T a) where ...
Note that 'b' isn't a parameter of T.  This gives rise to all sorts of
problems; in particular, it's hard to compare solutions for equality
when finding the fixpoint, and that means the inferContext loop does
not converge.  See Trac #5287.

\begin{code}
validDerivPred :: TyVarSet -> PredType -> Bool
validDerivPred tv_set ty = case getClassPredTys_maybe ty of
  Just (_, tys) | let fvs = fvTypes tys
                -> hasNoDups fvs 
                && sizeTypes tys == length fvs
                && all (`elemVarSet` tv_set) fvs
  _ -> False
\end{code}


%************************************************************************
%*									*
\subsection{Checking instance for termination}
%*									*
%************************************************************************

\begin{code}
checkValidInstance :: UserTypeCtxt -> LHsType Name -> [TyVar] -> ThetaType
                   -> Class -> [TcType] -> TcM ()
checkValidInstance ctxt hs_type tyvars theta clas inst_tys
  = setSrcSpan (getLoc hs_type) $
    do  { setSrcSpan head_loc (checkValidInstHead ctxt clas inst_tys)
        ; checkValidTheta ctxt theta
	; checkAmbiguity tyvars theta (tyVarsOfTypes inst_tys)

	-- Check that instance inference will terminate (if we care)
	-- For Haskell 98 this will already have been done by checkValidTheta,
        -- but as we may be using other extensions we need to check.
	; undecidable_ok <- xoptM Opt_UndecidableInstances
        ; unless undecidable_ok $
	  mapM_ addErrTc (checkInstTermination inst_tys theta)
	
	-- The Coverage Condition
	; checkTc (undecidable_ok || checkInstCoverage clas inst_tys)
	  	  (instTypeErr (pprClassPred clas inst_tys) msg)
        }
  where
    msg  = parens (vcat [ptext (sLit "the Coverage Condition fails for one of the functional dependencies;"),
			 undecidableMsg])

        -- The location of the "head" of the instance
    head_loc = case hs_type of
                 L _ (HsForAllTy _ _ _ (L loc _)) -> loc
                 L loc _                          -> loc
\end{code}

Note [Paterson conditions]
~~~~~~~~~~~~~~~~~~~~~~~~~~

Termination test: the so-called "Paterson conditions" (see Section 5 of
"Understanding functionsl dependencies via Constraint Handling Rules, 
JFP Jan 2007).

We check that each assertion in the context satisfies:
 (1) no variable has more occurrences in the assertion than in the head, and
 (2) the assertion has fewer constructors and variables (taken together
     and counting repetitions) than the head.
This is only needed with -fglasgow-exts, as Haskell 98 restrictions
(which have already been checked) guarantee termination. 

The underlying idea is that 

    for any ground substitution, each assertion in the
    context has fewer type constructors than the head.


\begin{code}
checkInstTermination :: [TcType] -> ThetaType -> [Message]
checkInstTermination tys theta
  = mapCatMaybes check theta
  where
   fvs  = fvTypes tys
   size = sizeTypes tys
   check pred 
      | not (null (fvType pred \\ fvs)) 
      = Just (predUndecErr pred nomoreMsg $$ parens undecidableMsg)
      | sizePred pred >= size
      = Just (predUndecErr pred smallerMsg $$ parens undecidableMsg)
      | otherwise
      = Nothing

predUndecErr :: PredType -> SDoc -> SDoc
predUndecErr pred msg = sep [msg,
			nest 2 (ptext (sLit "in the constraint:") <+> pprType pred)]

nomoreMsg, smallerMsg, undecidableMsg :: SDoc
nomoreMsg = ptext (sLit "Variable occurs more often in a constraint than in the instance head")
smallerMsg = ptext (sLit "Constraint is no smaller than the instance head")
undecidableMsg = ptext (sLit "Use -XUndecidableInstances to permit this")
\end{code}


%************************************************************************
%*									*
	Checking type instance well-formedness and termination
%*									*
%************************************************************************

\begin{code}
-- Check that a "type instance" is well-formed (which includes decidability
-- unless -XUndecidableInstances is given).
--
checkValidFamInst :: [Type] -> Type -> TcM ()
checkValidFamInst typats rhs
  = do { -- left-hand side contains no type family applications
         -- (vanilla synonyms are fine, though)
       ; mapM_ checkTyFamFreeness typats

         -- the right-hand side is a tau type
       ; checkValidMonoType rhs

         -- we have a decidable instance unless otherwise permitted
       ; undecidable_ok <- xoptM Opt_UndecidableInstances
       ; unless undecidable_ok $
	   mapM_ addErrTc (checkFamInstRhs typats (tcTyFamInsts rhs))
       }

-- Make sure that each type family instance is 
--   (1) strictly smaller than the lhs,
--   (2) mentions no type variable more often than the lhs, and
--   (3) does not contain any further type family instances.
--
checkFamInstRhs :: [Type]                  -- lhs
             	-> [(TyCon, [Type])]       -- type family instances
             	-> [Message]
checkFamInstRhs lhsTys famInsts
  = mapCatMaybes check famInsts
  where
   size = sizeTypes lhsTys
   fvs  = fvTypes lhsTys
   check (tc, tys)
      | not (all isTyFamFree tys)
      = Just (famInstUndecErr famInst nestedMsg $$ parens undecidableMsg)
      | not (null (fvTypes tys \\ fvs))
      = Just (famInstUndecErr famInst nomoreVarMsg $$ parens undecidableMsg)
      | size <= sizeTypes tys
      = Just (famInstUndecErr famInst smallerAppMsg $$ parens undecidableMsg)
      | otherwise
      = Nothing
      where
        famInst = TyConApp tc tys

-- Ensure that no type family instances occur in a type.
--
checkTyFamFreeness :: Type -> TcM ()
checkTyFamFreeness ty
  = checkTc (isTyFamFree ty) $
      tyFamInstIllegalErr ty

-- Check that a type does not contain any type family applications.
--
isTyFamFree :: Type -> Bool
isTyFamFree = null . tcTyFamInsts

-- Error messages

tyFamInstIllegalErr :: Type -> SDoc
tyFamInstIllegalErr ty
  = hang (ptext (sLit "Illegal type synonym family application in instance") <> 
         colon) 2 $
      ppr ty

famInstUndecErr :: Type -> SDoc -> SDoc
famInstUndecErr ty msg 
  = sep [msg, 
         nest 2 (ptext (sLit "in the type family application:") <+> 
                 pprType ty)]

nestedMsg, nomoreVarMsg, smallerAppMsg :: SDoc
nestedMsg     = ptext (sLit "Nested type family application")
nomoreVarMsg  = ptext (sLit "Variable occurs more often than in instance head")
smallerAppMsg = ptext (sLit "Application is no smaller than the instance head")
\end{code}


%************************************************************************
%*									*
\subsection{Auxiliary functions}
%*									*
%************************************************************************

\begin{code}
-- Free variables of a type, retaining repetitions, and expanding synonyms
fvType :: Type -> [TyVar]
fvType ty | Just exp_ty <- tcView ty = fvType exp_ty
fvType (TyVarTy tv)        = [tv]
fvType (TyConApp _ tys)    = fvTypes tys
fvType (FunTy arg res)     = fvType arg ++ fvType res
fvType (AppTy fun arg)     = fvType fun ++ fvType arg
fvType (ForAllTy tyvar ty) = filter (/= tyvar) (fvType ty)

fvTypes :: [Type] -> [TyVar]
fvTypes tys                = concat (map fvType tys)

sizeType :: Type -> Int
-- Size of a type: the number of variables and constructors
sizeType ty | Just exp_ty <- tcView ty = sizeType exp_ty
sizeType (TyVarTy _)       = 1
sizeType (TyConApp _ tys)  = sizeTypes tys + 1
sizeType (FunTy arg res)   = sizeType arg + sizeType res + 1
sizeType (AppTy fun arg)   = sizeType fun + sizeType arg
sizeType (ForAllTy _ ty)   = sizeType ty

sizeTypes :: [Type] -> Int
-- IA0_NOTE: Avoid kinds.
sizeTypes xs = sum (map sizeType tys)
  where tys = filter (not . isKind) xs

-- Size of a predicate
--
-- We are considering whether *class* constraints terminate
-- Once we get into an implicit parameter or equality we
-- can't get back to a class constraint, so it's safe
-- to say "size 0".  See Trac #4200.
sizePred :: PredType -> Int
sizePred ty = go (classifyPredType ty)
  where
    go (ClassPred _ tys') = sizeTypes tys'
    go (IPPred {})        = 0
    go (EqPred {})        = 0
    go (TuplePred ts)     = sum (map (go . classifyPredType) ts)
    go (IrredPred ty)     = sizeType ty
\end{code}

Note [Paterson conditions on PredTypes]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
We are considering whether *class* constraints terminate
(see Note [Paterson conditions]). Precisely, the Paterson conditions
would have us check that "the constraint has fewer constructors and variables
(taken together and counting repetitions) than the head.".

However, we can be a bit more refined by looking at which kind of constraint
this actually is. There are two main tricks:

 1. It seems like it should be OK not to count the tuple type constructor
    for a PredType like (Show a, Eq a) :: Constraint, since we don't
    count the "implicit" tuple in the ThetaType itself.

    In fact, the Paterson test just checks *each component* of the top level
    ThetaType against the size bound, one at a time. By analogy, it should be
    OK to return the size of the *largest* tuple component as the size of the
    whole tuple.

 2. Once we get into an implicit parameter or equality we
    can't get back to a class constraint, so it's safe
    to say "size 0".  See Trac #4200.

NB: we don't want to detect PredTypes in sizeType (and then call 
sizePred on them), or we might get an infinite loop if that PredType
is irreducible. See Trac #5581.
