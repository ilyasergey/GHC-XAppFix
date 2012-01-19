%
% (c) The University of Glasgow 2006
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%

TcMatches: Typecheck some @Matches@

\begin{code}
{-# OPTIONS -fno-warn-tabs #-}
-- The above warning supression flag is a temporary kludge.
-- While working on this module you are encouraged to remove it and
-- detab the module (please do the detabbing in a separate patch). See
--     http://hackage.haskell.org/trac/ghc/wiki/Commentary/CodingStyle#TabsvsSpaces
-- for details

module TcMatches ( tcMatchesFun, tcGRHSsPat, tcMatchesCase, tcMatchLambda,
		   TcMatchCtxt(..), TcStmtChecker,
		   tcStmts, tcStmtsAndThen, tcDoStmts, tcBody,
		   tcDoStmt, tcGuardStmt
       ) where

import {-# SOURCE #-}	TcExpr( tcSyntaxOp, tcInferRhoNC, tcInferRho, tcCheckId,
                                tcMonoExpr, tcMonoExprNC, tcPolyExpr )

import HsSyn
import BasicTypes
import TcRnMonad
import TcEnv
import TcPat
import TcMType
import TcType
import TcBinds
import TcUnify
import Name
import TysWiredIn
import Id
import TyCon
import TysPrim
import TcEvidence
import Outputable
import Util
import SrcLoc
import FastString

-- Create chunkified tuple tybes for monad comprehensions
import MkCore

import Control.Monad

#include "HsVersions.h"
\end{code}

%************************************************************************
%*									*
\subsection{tcMatchesFun, tcMatchesCase}
%*									*
%************************************************************************

@tcMatchesFun@ typechecks a @[Match]@ list which occurs in a
@FunMonoBind@.  The second argument is the name of the function, which
is used in error messages.  It checks that all the equations have the
same number of arguments before using @tcMatches@ to do the work.

Note [Polymorphic expected type for tcMatchesFun]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
tcMatchesFun may be given a *sigma* (polymorphic) type
so it must be prepared to use tcGen to skolemise it.
See Note [sig_tau may be polymorphic] in TcPat.

\begin{code}
tcMatchesFun :: Name -> Bool
	     -> MatchGroup Name
	     -> TcSigmaType			   -- Expected type of function
	     -> TcM (HsWrapper, MatchGroup TcId)   -- Returns type of body
tcMatchesFun fun_name inf matches exp_ty
  = do	{  -- Check that they all have the same no of arguments
	   -- Location is in the monad, set the caller so that 
	   -- any inter-equation error messages get some vaguely
	   -- sensible location.	Note: we have to do this odd
	   -- ann-grabbing, because we don't always have annotations in
	   -- hand when we call tcMatchesFun...
          traceTc "tcMatchesFun" (ppr fun_name $$ ppr exp_ty)
	; checkArgs fun_name matches

	; (wrap_gen, (wrap_fun, group)) 
            <- tcGen (FunSigCtxt fun_name) exp_ty $ \ _ exp_rho ->
	          -- Note [Polymorphic expected type for tcMatchesFun]
               matchFunTys herald arity exp_rho $ \ pat_tys rhs_ty -> 
	       tcMatches match_ctxt pat_tys rhs_ty matches 
        ; return (wrap_gen <.> wrap_fun, group) }
  where
    arity = matchGroupArity matches
    herald = ptext (sLit "The equation(s) for")
             <+> quotes (ppr fun_name) <+> ptext (sLit "have")
    match_ctxt = MC { mc_what = FunRhs fun_name inf, mc_body = tcBody }
\end{code}

@tcMatchesCase@ doesn't do the argument-count check because the
parser guarantees that each equation has exactly one argument.

\begin{code}
tcMatchesCase :: TcMatchCtxt		-- Case context
	      -> TcRhoType		-- Type of scrutinee
	      -> MatchGroup Name	-- The case alternatives
	      -> TcRhoType 		-- Type of whole case expressions
	      -> TcM (MatchGroup TcId)	-- Translated alternatives

tcMatchesCase ctxt scrut_ty matches res_ty
  | isEmptyMatchGroup matches   -- Allow empty case expressions
  = return (MatchGroup [] (mkFunTys [scrut_ty] res_ty)) 

  | otherwise
  = tcMatches ctxt [scrut_ty] res_ty matches

tcMatchLambda :: MatchGroup Name -> TcRhoType -> TcM (HsWrapper, MatchGroup TcId)
tcMatchLambda match res_ty 
  = matchFunTys herald n_pats res_ty  $ \ pat_tys rhs_ty ->
    tcMatches match_ctxt pat_tys rhs_ty match
  where
    n_pats = matchGroupArity match
    herald = sep [ ptext (sLit "The lambda expression")
	        	 <+> quotes (pprSetDepth (PartWay 1) $ 
                             pprMatches (LambdaExpr :: HsMatchContext Name) match),
			-- The pprSetDepth makes the abstraction print briefly
		ptext (sLit "has")]
    match_ctxt = MC { mc_what = LambdaExpr,
		      mc_body = tcBody }
\end{code}

@tcGRHSsPat@ typechecks @[GRHSs]@ that occur in a @PatMonoBind@.

\begin{code}
tcGRHSsPat :: GRHSs Name -> TcRhoType -> TcM (GRHSs TcId)
-- Used for pattern bindings
tcGRHSsPat grhss res_ty = tcGRHSs match_ctxt grhss res_ty
  where
    match_ctxt = MC { mc_what = PatBindRhs,
		      mc_body = tcBody }
\end{code}


\begin{code}
matchFunTys
  :: SDoc	-- See Note [Herald for matchExpecteFunTys] in TcUnify
  -> Arity
  -> TcRhoType
  -> ([TcSigmaType] -> TcRhoType -> TcM a)
  -> TcM (HsWrapper, a)

-- Written in CPS style for historical reasons; 
-- could probably be un-CPSd, like matchExpectedTyConApp

matchFunTys herald arity res_ty thing_inside
  = do	{ (co, pat_tys, res_ty) <- matchExpectedFunTys herald arity res_ty
	; res <- thing_inside pat_tys res_ty
        ; return (coToHsWrapper (mkTcSymCo co), res) }
\end{code}

%************************************************************************
%*									*
\subsection{tcMatch}
%*									*
%************************************************************************

\begin{code}
tcMatches :: TcMatchCtxt
	  -> [TcSigmaType] 	-- Expected pattern types
	  -> TcRhoType		-- Expected result-type of the Match.
	  -> MatchGroup Name
	  -> TcM (MatchGroup TcId)

data TcMatchCtxt 	-- c.f. TcStmtCtxt, also in this module
  = MC { mc_what :: HsMatchContext Name,	-- What kind of thing this is
    	 mc_body :: LHsExpr Name 		-- Type checker for a body of
                                                -- an alternative
		 -> TcRhoType
		 -> TcM (LHsExpr TcId) }	

tcMatches ctxt pat_tys rhs_ty (MatchGroup matches _)
  = ASSERT( not (null matches) )	-- Ensure that rhs_ty is filled in
    do	{ matches' <- mapM (tcMatch ctxt pat_tys rhs_ty) matches
	; return (MatchGroup matches' (mkFunTys pat_tys rhs_ty)) }

-------------
tcMatch :: TcMatchCtxt
	-> [TcSigmaType]	-- Expected pattern types
	-> TcRhoType	 	-- Expected result-type of the Match.
	-> LMatch Name
	-> TcM (LMatch TcId)

tcMatch ctxt pat_tys rhs_ty match 
  = wrapLocM (tc_match ctxt pat_tys rhs_ty) match
  where
    tc_match ctxt pat_tys rhs_ty match@(Match pats maybe_rhs_sig grhss)
      = add_match_ctxt match $
        do { (pats', grhss') <- tcPats (mc_what ctxt) pats pat_tys $
    			        tc_grhss ctxt maybe_rhs_sig grhss rhs_ty
	   ; return (Match pats' Nothing grhss') }

    tc_grhss ctxt Nothing grhss rhs_ty 
      = tcGRHSs ctxt grhss rhs_ty	-- No result signature

	-- Result type sigs are no longer supported
    tc_grhss _ (Just {}) _ _
      = panic "tc_ghrss"  	-- Rejected by renamer

	-- For (\x -> e), tcExpr has already said "In the expresssion \x->e"
	-- so we don't want to add "In the lambda abstraction \x->e"
    add_match_ctxt match thing_inside
	= case mc_what ctxt of
	    LambdaExpr -> thing_inside
	    m_ctxt     -> addErrCtxt (pprMatchInCtxt m_ctxt match) thing_inside

-------------
tcGRHSs :: TcMatchCtxt -> GRHSs Name -> TcRhoType
	-> TcM (GRHSs TcId)

-- Notice that we pass in the full res_ty, so that we get
-- good inference from simple things like
--	f = \(x::forall a.a->a) -> <stuff>
-- We used to force it to be a monotype when there was more than one guard
-- but we don't need to do that any more

tcGRHSs ctxt (GRHSs grhss binds) res_ty
  = do	{ (binds', grhss') <- tcLocalBinds binds $
			      mapM (wrapLocM (tcGRHS ctxt res_ty)) grhss

	; return (GRHSs grhss' binds') }

-------------
tcGRHS :: TcMatchCtxt -> TcRhoType -> GRHS Name -> TcM (GRHS TcId)

tcGRHS ctxt res_ty (GRHS guards rhs)
  = do  { (guards', rhs') <- tcStmtsAndThen stmt_ctxt tcGuardStmt guards res_ty $
			     mc_body ctxt rhs
	; return (GRHS guards' rhs') }
  where
    stmt_ctxt  = PatGuard (mc_what ctxt)
\end{code}


%************************************************************************
%*									*
\subsection{@tcDoStmts@ typechecks a {\em list} of do statements}
%*									*
%************************************************************************

\begin{code}
tcDoStmts :: HsStmtContext Name 
	  -> [LStmt Name]
	  -> TcRhoType
	  -> TcM (HsExpr TcId)		-- Returns a HsDo
tcDoStmts ListComp stmts res_ty
  = do	{ (co, elt_ty) <- matchExpectedListTy res_ty
        ; let list_ty = mkListTy elt_ty
	; stmts' <- tcStmts ListComp (tcLcStmt listTyCon) stmts elt_ty
	; return $ mkHsWrapCo co (HsDo ListComp stmts' list_ty) }

tcDoStmts PArrComp stmts res_ty
  = do	{ (co, elt_ty) <- matchExpectedPArrTy res_ty
        ; let parr_ty = mkPArrTy elt_ty
	; stmts' <- tcStmts PArrComp (tcLcStmt parrTyCon) stmts elt_ty
	; return $ mkHsWrapCo co (HsDo PArrComp stmts' parr_ty) }

tcDoStmts DoExpr stmts res_ty
  = do	{ stmts' <- tcStmts DoExpr tcDoStmt stmts res_ty
	; return (HsDo DoExpr stmts' res_ty) }

tcDoStmts MDoExpr stmts res_ty
  = do  { stmts' <- tcStmts MDoExpr tcDoStmt stmts res_ty
        ; return (HsDo MDoExpr stmts' res_ty) }

tcDoStmts MonadComp stmts res_ty
  = do  { stmts' <- tcStmts MonadComp tcMcStmt stmts res_ty 
        ; return (HsDo MonadComp stmts' res_ty) }

tcDoStmts ctxt _ _ = pprPanic "tcDoStmts" (pprStmtContext ctxt)

tcBody :: LHsExpr Name -> TcRhoType -> TcM (LHsExpr TcId)
tcBody body res_ty
  = do	{ traceTc "tcBody" (ppr res_ty)
	; body' <- tcMonoExpr body res_ty
	; return body' 
        } 
\end{code}


%************************************************************************
%*									*
\subsection{tcStmts}
%*									*
%************************************************************************

\begin{code}
type TcStmtChecker
  =  forall thing. HsStmtContext Name
        	-> Stmt Name
		-> TcRhoType			-- Result type for comprehension
	      	-> (TcRhoType -> TcM thing)	-- Checker for what follows the stmt
              	-> TcM (Stmt TcId, thing)

tcStmts :: HsStmtContext Name
	-> TcStmtChecker	-- NB: higher-rank type
        -> [LStmt Name]
	-> TcRhoType
        -> TcM [LStmt TcId]
tcStmts ctxt stmt_chk stmts res_ty
  = do { (stmts', _) <- tcStmtsAndThen ctxt stmt_chk stmts res_ty $
                        const (return ())
       ; return stmts' }

tcStmtsAndThen :: HsStmtContext Name
	       -> TcStmtChecker	-- NB: higher-rank type
               -> [LStmt Name]
	       -> TcRhoType
	       -> (TcRhoType -> TcM thing)
               -> TcM ([LStmt TcId], thing)

-- Note the higher-rank type.  stmt_chk is applied at different
-- types in the equations for tcStmts

tcStmtsAndThen _ _ [] res_ty thing_inside
  = do	{ thing <- thing_inside res_ty
	; return ([], thing) }

-- LetStmts are handled uniformly, regardless of context
tcStmtsAndThen ctxt stmt_chk (L loc (LetStmt binds) : stmts) res_ty thing_inside
  = do	{ (binds', (stmts',thing)) <- tcLocalBinds binds $
				      tcStmtsAndThen ctxt stmt_chk stmts res_ty thing_inside
	; return (L loc (LetStmt binds') : stmts', thing) }

-- For the vanilla case, handle the location-setting part
tcStmtsAndThen ctxt stmt_chk (L loc stmt : stmts) res_ty thing_inside
  = do 	{ (stmt', (stmts', thing)) <- 
		setSrcSpan loc		 		    $
    		addErrCtxt (pprStmtInCtxt ctxt stmt)	    $
		stmt_chk ctxt stmt res_ty		    $ \ res_ty' ->
		popErrCtxt 				    $
		tcStmtsAndThen ctxt stmt_chk stmts res_ty'  $
		thing_inside
	; return (L loc stmt' : stmts', thing) }

---------------------------------------------------
--	        Pattern guards
---------------------------------------------------

tcGuardStmt :: TcStmtChecker
tcGuardStmt _ (ExprStmt guard _ _ _) res_ty thing_inside
  = do	{ guard' <- tcMonoExpr guard boolTy
	; thing  <- thing_inside res_ty
	; return (ExprStmt guard' noSyntaxExpr noSyntaxExpr boolTy, thing) }

tcGuardStmt ctxt (BindStmt pat rhs _ _) res_ty thing_inside
  = do	{ (rhs', rhs_ty) <- tcInferRhoNC rhs	-- Stmt has a context already
	; (pat', thing)  <- tcPat (StmtCtxt ctxt) pat rhs_ty $
                            thing_inside res_ty
	; return (BindStmt pat' rhs' noSyntaxExpr noSyntaxExpr, thing) }

tcGuardStmt _ stmt _ _
  = pprPanic "tcGuardStmt: unexpected Stmt" (ppr stmt)


---------------------------------------------------
--	     List comprehensions and PArrays
--	         (no rebindable syntax)
---------------------------------------------------

-- Dealt with separately, rather than by tcMcStmt, because
--   a) PArr isn't (yet) an instance of Monad, so the generality seems overkill
--   b) We have special desugaring rules for list comprehensions,
--      which avoid creating intermediate lists.  They in turn 
--      assume that the bind/return operations are the regular
--      polymorphic ones, and in particular don't have any
--      coercion matching stuff in them.  It's hard to avoid the
--      potential for non-trivial coercions in tcMcStmt

tcLcStmt :: TyCon	-- The list/Parray type constructor ([] or PArray)
	 -> TcStmtChecker

tcLcStmt _ _ (LastStmt body _) elt_ty thing_inside
  = do { body' <- tcMonoExprNC body elt_ty
       ; thing <- thing_inside (panic "tcLcStmt: thing_inside")
       ; return (LastStmt body' noSyntaxExpr, thing) }

-- A generator, pat <- rhs
tcLcStmt m_tc ctxt (BindStmt pat rhs _ _) elt_ty thing_inside
 = do	{ pat_ty <- newFlexiTyVarTy liftedTypeKind
        ; rhs'   <- tcMonoExpr rhs (mkTyConApp m_tc [pat_ty])
	; (pat', thing)  <- tcPat (StmtCtxt ctxt) pat pat_ty $
                            thing_inside elt_ty
	; return (BindStmt pat' rhs' noSyntaxExpr noSyntaxExpr, thing) }

-- A boolean guard
tcLcStmt _ _ (ExprStmt rhs _ _ _) elt_ty thing_inside
  = do	{ rhs'  <- tcMonoExpr rhs boolTy
	; thing <- thing_inside elt_ty
	; return (ExprStmt rhs' noSyntaxExpr noSyntaxExpr boolTy, thing) }

-- ParStmt: See notes with tcMcStmt
tcLcStmt m_tc ctxt (ParStmt bndr_stmts_s _ _ _) elt_ty thing_inside
  = do	{ (pairs', thing) <- loop bndr_stmts_s
	; return (ParStmt pairs' noSyntaxExpr noSyntaxExpr noSyntaxExpr, thing) }
  where
    -- loop :: [([LStmt Name], [Name])] -> TcM ([([LStmt TcId], [TcId])], thing)
    loop [] = do { thing <- thing_inside elt_ty
		 ; return ([], thing) }		-- matching in the branches

    loop ((stmts, names) : pairs)
      = do { (stmts', (ids, pairs', thing))
		<- tcStmtsAndThen ctxt (tcLcStmt m_tc) stmts elt_ty $ \ _elt_ty' ->
		   do { ids <- tcLookupLocalIds names
		      ; (pairs', thing) <- loop pairs
		      ; return (ids, pairs', thing) }
	   ; return ( (stmts', ids) : pairs', thing ) }

tcLcStmt m_tc ctxt (TransStmt { trS_form = form, trS_stmts = stmts
                              , trS_bndrs =  bindersMap
                              , trS_by = by, trS_using = using }) elt_ty thing_inside
  = do { let (bndr_names, n_bndr_names) = unzip bindersMap
             unused_ty = pprPanic "tcLcStmt: inner ty" (ppr bindersMap)
       	     -- The inner 'stmts' lack a LastStmt, so the element type
	     --  passed in to tcStmtsAndThen is never looked at
       ; (stmts', (bndr_ids, by'))
            <- tcStmtsAndThen (TransStmtCtxt ctxt) (tcLcStmt m_tc) stmts unused_ty $ \_ -> do
	       { by' <- case by of
                           Nothing -> return Nothing
                           Just e  -> do { e_ty <- tcInferRho e; return (Just e_ty) }
               ; bndr_ids <- tcLookupLocalIds bndr_names
               ; return (bndr_ids, by') }

       ; let m_app ty = mkTyConApp m_tc [ty]

       --------------- Typecheck the 'using' function -------------
       -- using :: ((a,b,c)->t) -> m (a,b,c) -> m (a,b,c)m      (ThenForm)
       --       :: ((a,b,c)->t) -> m (a,b,c) -> m (m (a,b,c)))  (GroupForm)

         -- n_app :: Type -> Type   -- Wraps a 'ty' into '[ty]' for GroupForm
       ; let n_app = case form of
                       ThenForm -> (\ty -> ty)
  		       _ 	-> m_app

             by_arrow :: Type -> Type     -- Wraps 'ty' to '(a->t) -> ty' if the By is present
             by_arrow = case by' of
                          Nothing       -> \ty -> ty
                          Just (_,e_ty) -> \ty -> (alphaTy `mkFunTy` e_ty) `mkFunTy` ty

             tup_ty        = mkBigCoreVarTupTy bndr_ids
             poly_arg_ty   = m_app alphaTy
	     poly_res_ty   = m_app (n_app alphaTy)
	     using_poly_ty = mkForAllTy alphaTyVar $ by_arrow $ 
                             poly_arg_ty `mkFunTy` poly_res_ty

       ; using' <- tcPolyExpr using using_poly_ty
       ; let final_using = fmap (HsWrap (WpTyApp tup_ty)) using' 

	     -- 'stmts' returns a result of type (m1_ty tuple_ty),
	     -- typically something like [(Int,Bool,Int)]
	     -- We don't know what tuple_ty is yet, so we use a variable
       ; let mk_n_bndr :: Name -> TcId -> TcId
             mk_n_bndr n_bndr_name bndr_id = mkLocalId n_bndr_name (n_app (idType bndr_id))

             -- Ensure that every old binder of type `b` is linked up with its
             -- new binder which should have type `n b`
	     -- See Note [GroupStmt binder map] in HsExpr
             n_bndr_ids  = zipWith mk_n_bndr n_bndr_names bndr_ids
             bindersMap' = bndr_ids `zip` n_bndr_ids

       -- Type check the thing in the environment with 
       -- these new binders and return the result
       ; thing <- tcExtendIdEnv n_bndr_ids (thing_inside elt_ty)

       ; return (emptyTransStmt { trS_stmts = stmts', trS_bndrs = bindersMap' 
                                , trS_by = fmap fst by', trS_using = final_using 
                                , trS_form = form }, thing) }
    
tcLcStmt _ _ stmt _ _
  = pprPanic "tcLcStmt: unexpected Stmt" (ppr stmt)


---------------------------------------------------
--	     Monad comprehensions 
--	  (supports rebindable syntax)
---------------------------------------------------

tcMcStmt :: TcStmtChecker

tcMcStmt _ (LastStmt body return_op) res_ty thing_inside
  = do  { a_ty       <- newFlexiTyVarTy liftedTypeKind
        ; return_op' <- tcSyntaxOp MCompOrigin return_op
                                   (a_ty `mkFunTy` res_ty)
        ; body'      <- tcMonoExprNC body a_ty
        ; thing      <- thing_inside (panic "tcMcStmt: thing_inside")
        ; return (LastStmt body' return_op', thing) } 

-- Generators for monad comprehensions ( pat <- rhs )
--
--   [ body | q <- gen ]  ->  gen :: m a
--                            q   ::   a
--

tcMcStmt ctxt (BindStmt pat rhs bind_op fail_op) res_ty thing_inside
 = do   { rhs_ty     <- newFlexiTyVarTy liftedTypeKind
        ; pat_ty     <- newFlexiTyVarTy liftedTypeKind
        ; new_res_ty <- newFlexiTyVarTy liftedTypeKind

	   -- (>>=) :: rhs_ty -> (pat_ty -> new_res_ty) -> res_ty
        ; bind_op'   <- tcSyntaxOp MCompOrigin bind_op 
                             (mkFunTys [rhs_ty, mkFunTy pat_ty new_res_ty] res_ty)

           -- If (but only if) the pattern can fail, typecheck the 'fail' operator
        ; fail_op' <- if isIrrefutableHsPat pat 
                      then return noSyntaxExpr
                      else tcSyntaxOp MCompOrigin fail_op (mkFunTy stringTy new_res_ty)

        ; rhs' <- tcMonoExprNC rhs rhs_ty
        ; (pat', thing) <- tcPat (StmtCtxt ctxt) pat pat_ty $
                           thing_inside new_res_ty

        ; return (BindStmt pat' rhs' bind_op' fail_op', thing) }

-- Boolean expressions.
--
--   [ body | stmts, expr ]  ->  expr :: m Bool
--
tcMcStmt _ (ExprStmt rhs then_op guard_op _) res_ty thing_inside
  = do	{ -- Deal with rebindable syntax:
          --    guard_op :: test_ty -> rhs_ty
          --    then_op  :: rhs_ty -> new_res_ty -> res_ty
          -- Where test_ty is, for example, Bool
          test_ty    <- newFlexiTyVarTy liftedTypeKind
        ; rhs_ty     <- newFlexiTyVarTy liftedTypeKind
        ; new_res_ty <- newFlexiTyVarTy liftedTypeKind
        ; rhs'       <- tcMonoExpr rhs test_ty
        ; guard_op'  <- tcSyntaxOp MCompOrigin guard_op
                                   (mkFunTy test_ty rhs_ty)
        ; then_op'   <- tcSyntaxOp MCompOrigin then_op
		                   (mkFunTys [rhs_ty, new_res_ty] res_ty)
	; thing      <- thing_inside new_res_ty
	; return (ExprStmt rhs' then_op' guard_op' rhs_ty, thing) }

-- Grouping statements
--
--   [ body | stmts, then group by e using f ]
--     ->  e :: t
--         f :: forall a. (a -> t) -> m a -> m (m a)
--   [ body | stmts, then group using f ]
--     ->  f :: forall a. m a -> m (m a)

-- We type [ body | (stmts, group by e using f), ... ]
--     f <optional by> [ (a,b,c) | stmts ] >>= \(a,b,c) -> ...body....
--
-- We type the functions as follows:
--     f <optional by> :: m1 (a,b,c) -> m2 (a,b,c)		(ThenForm)
--     	 	       :: m1 (a,b,c) -> m2 (n (a,b,c))		(GroupForm)
--     (>>=) :: m2 (a,b,c)     -> ((a,b,c)   -> res) -> res	(ThenForm)
--           :: m2 (n (a,b,c)) -> (n (a,b,c) -> res) -> res	(GroupForm)
-- 
tcMcStmt ctxt (TransStmt { trS_stmts = stmts, trS_bndrs = bindersMap
                         , trS_by = by, trS_using = using, trS_form = form
                         , trS_ret = return_op, trS_bind = bind_op 
                         , trS_fmap = fmap_op }) res_ty thing_inside
  = do { let star_star_kind = liftedTypeKind `mkArrowKind` liftedTypeKind
       ; m1_ty   <- newFlexiTyVarTy star_star_kind
       ; m2_ty   <- newFlexiTyVarTy star_star_kind
       ; tup_ty  <- newFlexiTyVarTy liftedTypeKind
       ; by_e_ty <- newFlexiTyVarTy liftedTypeKind  -- The type of the 'by' expression (if any)

         -- n_app :: Type -> Type   -- Wraps a 'ty' into '(n ty)' for GroupForm
       ; n_app <- case form of
                    ThenForm -> return (\ty -> ty)
		    _ 	     -> do { n_ty <- newFlexiTyVarTy star_star_kind
                      	           ; return (n_ty `mkAppTy`) }
       ; let by_arrow :: Type -> Type     
             -- (by_arrow res) produces ((alpha->e_ty) -> res)     ('by' present)
             --                          or res                    ('by' absent) 
             by_arrow = case by of
                          Nothing -> \res -> res
                          Just {} -> \res -> (alphaTy `mkFunTy` by_e_ty) `mkFunTy` res

             poly_arg_ty  = m1_ty `mkAppTy` alphaTy
             using_arg_ty = m1_ty `mkAppTy` tup_ty
	     poly_res_ty  = m2_ty `mkAppTy` n_app alphaTy
	     using_res_ty = m2_ty `mkAppTy` n_app tup_ty
	     using_poly_ty = mkForAllTy alphaTyVar $ by_arrow $ 
                             poly_arg_ty `mkFunTy` poly_res_ty

	     -- 'stmts' returns a result of type (m1_ty tuple_ty),
	     -- typically something like [(Int,Bool,Int)]
	     -- We don't know what tuple_ty is yet, so we use a variable
       ; let (bndr_names, n_bndr_names) = unzip bindersMap
       ; (stmts', (bndr_ids, by', return_op')) <-
            tcStmtsAndThen (TransStmtCtxt ctxt) tcMcStmt stmts using_arg_ty $ \res_ty' -> do
	        { by' <- case by of
                           Nothing -> return Nothing
                           Just e  -> do { e' <- tcMonoExpr e by_e_ty; return (Just e') }

                -- Find the Ids (and hence types) of all old binders
                ; bndr_ids <- tcLookupLocalIds bndr_names

                -- 'return' is only used for the binders, so we know its type.
                --   return :: (a,b,c,..) -> m (a,b,c,..)
                ; return_op' <- tcSyntaxOp MCompOrigin return_op $ 
                                (mkBigCoreVarTupTy bndr_ids) `mkFunTy` res_ty'

                ; return (bndr_ids, by', return_op') }

       --------------- Typecheck the 'bind' function -------------
       -- (>>=) :: m2 (n (a,b,c)) -> ( n (a,b,c) -> new_res_ty ) -> res_ty
       ; new_res_ty <- newFlexiTyVarTy liftedTypeKind
       ; bind_op' <- tcSyntaxOp MCompOrigin bind_op $
                                using_res_ty `mkFunTy` (n_app tup_ty `mkFunTy` new_res_ty)
                                             `mkFunTy` res_ty

       --------------- Typecheck the 'fmap' function -------------
       ; fmap_op' <- case form of
                       ThenForm -> return noSyntaxExpr
                       _ -> fmap unLoc . tcPolyExpr (noLoc fmap_op) $
                            mkForAllTy alphaTyVar $ mkForAllTy betaTyVar $
                            (alphaTy `mkFunTy` betaTy)
                            `mkFunTy` (n_app alphaTy)
                            `mkFunTy` (n_app betaTy)

       --------------- Typecheck the 'using' function -------------
       -- using :: ((a,b,c)->t) -> m1 (a,b,c) -> m2 (n (a,b,c))

       ; using' <- tcPolyExpr using using_poly_ty
       ; let final_using = fmap (HsWrap (WpTyApp tup_ty)) using' 

       --------------- Bulding the bindersMap ----------------
       ; let mk_n_bndr :: Name -> TcId -> TcId
             mk_n_bndr n_bndr_name bndr_id = mkLocalId n_bndr_name (n_app (idType bndr_id))

             -- Ensure that every old binder of type `b` is linked up with its
             -- new binder which should have type `n b`
	     -- See Note [GroupStmt binder map] in HsExpr
             n_bndr_ids = zipWith mk_n_bndr n_bndr_names bndr_ids
             bindersMap' = bndr_ids `zip` n_bndr_ids

       -- Type check the thing in the environment with 
       -- these new binders and return the result
       ; thing <- tcExtendIdEnv n_bndr_ids (thing_inside new_res_ty)

       ; return (TransStmt { trS_stmts = stmts', trS_bndrs = bindersMap' 
                           , trS_by = by', trS_using = final_using 
                           , trS_ret = return_op', trS_bind = bind_op'
                           , trS_fmap = fmap_op', trS_form = form }, thing) }

-- A parallel set of comprehensions
--	[ (g x, h x) | ... ; let g v = ...
--		     | ... ; let h v = ... ]
--
-- It's possible that g,h are overloaded, so we need to feed the LIE from the
-- (g x, h x) up through both lots of bindings (so we get the bindLocalMethods).
-- Similarly if we had an existential pattern match:
--
--	data T = forall a. Show a => C a
--
--	[ (show x, show y) | ... ; C x <- ...
--			   | ... ; C y <- ... ]
--
-- Then we need the LIE from (show x, show y) to be simplified against
-- the bindings for x and y.  
-- 
-- It's difficult to do this in parallel, so we rely on the renamer to 
-- ensure that g,h and x,y don't duplicate, and simply grow the environment.
-- So the binders of the first parallel group will be in scope in the second
-- group.  But that's fine; there's no shadowing to worry about.
--
-- Note: The `mzip` function will get typechecked via:
--
--   ParStmt [st1::t1, st2::t2, st3::t3]
--   
--   mzip :: m st1
--        -> (m st2 -> m st3 -> m (st2, st3))   -- recursive call
--        -> m (st1, (st2, st3))
--
tcMcStmt ctxt (ParStmt bndr_stmts_s mzip_op bind_op return_op) res_ty thing_inside
  = do { let star_star_kind = liftedTypeKind `mkArrowKind` liftedTypeKind
       ; m_ty   <- newFlexiTyVarTy star_star_kind

       ; let mzip_ty  = mkForAllTys [alphaTyVar, betaTyVar] $
                        (m_ty `mkAppTy` alphaTy)
                        `mkFunTy`
                        (m_ty `mkAppTy` betaTy)
                        `mkFunTy`
                        (m_ty `mkAppTy` mkBoxedTupleTy [alphaTy, betaTy])
       ; mzip_op' <- unLoc `fmap` tcPolyExpr (noLoc mzip_op) mzip_ty

       ; return_op' <- fmap unLoc . tcPolyExpr (noLoc return_op) $
                       mkForAllTy alphaTyVar $
                       alphaTy `mkFunTy` (m_ty `mkAppTy` alphaTy)

       ; (pairs', thing) <- loop m_ty bndr_stmts_s

       -- Typecheck bind:
       ; let tys      = map (mkBigCoreVarTupTy . snd) pairs'
             tuple_ty = mk_tuple_ty tys

       ; bind_op' <- tcSyntaxOp MCompOrigin bind_op $
                        (m_ty `mkAppTy` tuple_ty)
                        `mkFunTy` (tuple_ty `mkFunTy` res_ty)
                        `mkFunTy` res_ty

       ; return (ParStmt pairs' mzip_op' bind_op' return_op', thing) }

  where 
    mk_tuple_ty tys = foldr1 (\tn tm -> mkBoxedTupleTy [tn, tm]) tys

       -- loop :: Type                                  -- m_ty
       --      -> [([LStmt Name], [Name])]
       --      -> TcM ([([LStmt TcId], [TcId])], thing)
    loop _ [] = do { thing <- thing_inside res_ty
                   ; return ([], thing) }           -- matching in the branches

    loop m_ty ((stmts, names) : pairs)
      = do { -- type dummy since we don't know all binder types yet
             ty_dummy <- newFlexiTyVarTy liftedTypeKind
           ; (stmts', (ids, pairs', thing))
                <- tcStmtsAndThen ctxt tcMcStmt stmts ty_dummy $ \res_ty' ->
                   do { ids <- tcLookupLocalIds names
    		      ; let m_tup_ty = m_ty `mkAppTy` mkBigCoreVarTupTy ids

    		      ; check_same m_tup_ty res_ty'
    		      ; check_same m_tup_ty ty_dummy
    							 
                      ; (pairs', thing) <- loop m_ty pairs
                      ; return (ids, pairs', thing) }
           ; return ( (stmts', ids) : pairs', thing ) }

	-- Check that the types match up.
	-- This is a grevious hack.  They always *will* match 
	-- If (>>=) and (>>) are polymorpic in the return type,
	-- but we don't have any good way to incorporate the coercion
	-- so for now we just check that it's the identity
    check_same actual expected
      = do { co <- unifyType actual expected
	   ; unless (isTcReflCo co) $
             failWithMisMatch [UnifyOrigin { uo_expected = expected
                                           , uo_actual = actual }] }

tcMcStmt _ stmt _ _
  = pprPanic "tcMcStmt: unexpected Stmt" (ppr stmt)


---------------------------------------------------
--	     Do-notation
--	  (supports rebindable syntax)
---------------------------------------------------

tcDoStmt :: TcStmtChecker

tcDoStmt _ (LastStmt body _) res_ty thing_inside
  = do { body' <- tcMonoExprNC body res_ty
       ; thing <- thing_inside (panic "tcDoStmt: thing_inside")
       ; return (LastStmt body' noSyntaxExpr, thing) }

tcDoStmt ctxt (BindStmt pat rhs bind_op fail_op) res_ty thing_inside
  = do	{ 	-- Deal with rebindable syntax:
		--	 (>>=) :: rhs_ty -> (pat_ty -> new_res_ty) -> res_ty
		-- This level of generality is needed for using do-notation
		-- in full generality; see Trac #1537

		-- I'd like to put this *after* the tcSyntaxOp 
                -- (see Note [Treat rebindable syntax first], but that breaks 
		-- the rigidity info for GADTs.  When we move to the new story
                -- for GADTs, we can move this after tcSyntaxOp
          rhs_ty     <- newFlexiTyVarTy liftedTypeKind
        ; pat_ty     <- newFlexiTyVarTy liftedTypeKind
        ; new_res_ty <- newFlexiTyVarTy liftedTypeKind
	; bind_op'   <- tcSyntaxOp DoOrigin bind_op 
			     (mkFunTys [rhs_ty, mkFunTy pat_ty new_res_ty] res_ty)

		-- If (but only if) the pattern can fail, 
		-- typecheck the 'fail' operator
	; fail_op' <- if isIrrefutableHsPat pat 
		      then return noSyntaxExpr
		      else tcSyntaxOp DoOrigin fail_op (mkFunTy stringTy new_res_ty)

        ; rhs' <- tcMonoExprNC rhs rhs_ty
	; (pat', thing) <- tcPat (StmtCtxt ctxt) pat pat_ty $
                           thing_inside new_res_ty

	; return (BindStmt pat' rhs' bind_op' fail_op', thing) }


tcDoStmt _ (ExprStmt rhs then_op _ _) res_ty thing_inside
  = do	{   	-- Deal with rebindable syntax; 
                --   (>>) :: rhs_ty -> new_res_ty -> res_ty
		-- See also Note [Treat rebindable syntax first]
          rhs_ty     <- newFlexiTyVarTy liftedTypeKind
        ; new_res_ty <- newFlexiTyVarTy liftedTypeKind
	; then_op' <- tcSyntaxOp DoOrigin then_op 
			   (mkFunTys [rhs_ty, new_res_ty] res_ty)

        ; rhs' <- tcMonoExprNC rhs rhs_ty
	; thing <- thing_inside new_res_ty
	; return (ExprStmt rhs' then_op' noSyntaxExpr rhs_ty, thing) }

tcDoStmt ctxt (RecStmt { recS_stmts = stmts, recS_later_ids = later_names
                       , recS_rec_ids = rec_names, recS_ret_fn = ret_op
                       , recS_mfix_fn = mfix_op, recS_bind_fn = bind_op }) 
         res_ty thing_inside
  = do  { let tup_names = rec_names ++ filterOut (`elem` rec_names) later_names
        ; tup_elt_tys <- newFlexiTyVarTys (length tup_names) liftedTypeKind
        ; let tup_ids = zipWith mkLocalId tup_names tup_elt_tys
	      tup_ty  = mkBigCoreTupTy tup_elt_tys

        ; tcExtendIdEnv tup_ids $ do
        { stmts_ty <- newFlexiTyVarTy liftedTypeKind
        ; (stmts', (ret_op', tup_rets))
                <- tcStmtsAndThen ctxt tcDoStmt stmts stmts_ty   $ \ inner_res_ty ->
                   do { tup_rets <- zipWithM tcCheckId tup_names tup_elt_tys
                             -- Unify the types of the "final" Ids (which may 
                             -- be polymorphic) with those of "knot-tied" Ids
		      ; ret_op' <- tcSyntaxOp DoOrigin ret_op (mkFunTy tup_ty inner_res_ty)
                      ; return (ret_op', tup_rets) }

	; mfix_res_ty <- newFlexiTyVarTy liftedTypeKind
        ; mfix_op' <- tcSyntaxOp DoOrigin mfix_op
                                 (mkFunTy (mkFunTy tup_ty stmts_ty) mfix_res_ty)

	; new_res_ty <- newFlexiTyVarTy liftedTypeKind
        ; bind_op' <- tcSyntaxOp DoOrigin bind_op 
			         (mkFunTys [mfix_res_ty, mkFunTy tup_ty new_res_ty] res_ty)

        ; thing <- thing_inside new_res_ty
  
        ; let rec_ids = takeList rec_names tup_ids
	; later_ids <- tcLookupLocalIds later_names
	; traceTc "tcdo" $ vcat [ppr rec_ids <+> ppr (map idType rec_ids),
                                 ppr later_ids <+> ppr (map idType later_ids)]
        ; return (RecStmt { recS_stmts = stmts', recS_later_ids = later_ids
                          , recS_rec_ids = rec_ids, recS_ret_fn = ret_op' 
                          , recS_mfix_fn = mfix_op', recS_bind_fn = bind_op'
                          , recS_later_rets = [], recS_rec_rets = tup_rets
                          , recS_ret_ty = stmts_ty }, thing)
        }}

tcDoStmt _ stmt _ _
  = pprPanic "tcDoStmt: unexpected Stmt" (ppr stmt)
\end{code}

Note [Treat rebindable syntax first]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
When typechecking
	do { bar; ... } :: IO ()
we want to typecheck 'bar' in the knowledge that it should be an IO thing,
pushing info from the context into the RHS.  To do this, we check the
rebindable syntax first, and push that information into (tcMonoExprNC rhs).
Otherwise the error shows up when cheking the rebindable syntax, and
the expected/inferred stuff is back to front (see Trac #3613).


%************************************************************************
%*									*
\subsection{Errors and contexts}
%*									*
%************************************************************************

@sameNoOfArgs@ takes a @[RenamedMatch]@ and decides whether the same
number of args are used in each equation.

\begin{code}
checkArgs :: Name -> MatchGroup Name -> TcM ()
checkArgs fun (MatchGroup (match1:matches) _)
    | null bad_matches = return ()
    | otherwise
    = failWithTc (vcat [ptext (sLit "Equations for") <+> quotes (ppr fun) <+> 
			  ptext (sLit "have different numbers of arguments"),
			nest 2 (ppr (getLoc match1)),
			nest 2 (ppr (getLoc (head bad_matches)))])
  where
    n_args1 = args_in_match match1
    bad_matches = [m | m <- matches, args_in_match m /= n_args1]

    args_in_match :: LMatch Name -> Int
    args_in_match (L _ (Match pats _ _)) = length pats
checkArgs fun _ = pprPanic "TcPat.checkArgs" (ppr fun) -- Matches always non-empty
\end{code}

