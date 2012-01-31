%
% (c) The University of Glasgow 2006
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%

TcPat: Typechecking patterns

\begin{code}
{-# OPTIONS -fno-warn-tabs #-}
-- The above warning supression flag is a temporary kludge.
-- While working on this module you are encouraged to remove it and
-- detab the module (please do the detabbing in a separate patch). See
--     http://hackage.haskell.org/trac/ghc/wiki/Commentary/CodingStyle#TabsvsSpaces
-- for details

module TcPat ( tcLetPat, TcSigFun, TcSigInfo(..), TcPragFun 
             , LetBndrSpec(..), addInlinePrags, warnPrags
             , tcPat, tcPats, newNoSigLetBndr, newSigLetBndr, mkLocalBinder
	     , addDataConStupidTheta, badFieldCon, polyPatSig ) where

#include "HsVersions.h"

import {-# SOURCE #-}	TcExpr( tcSyntaxOp, tcInferRho)

import HsSyn
import TcHsSyn
import TcRnMonad
import Inst
import Id
import Var
import Name
import TcEnv
import TcMType
import TcType
import TcUnify
import TcHsType
import TysWiredIn
import TcEvidence
import StaticFlags
import TyCon
import DataCon
import PrelNames
import BasicTypes hiding (SuccessFlag(..))
import DynFlags
import SrcLoc
import Util
import Outputable
import FastString
import Control.Monad
\end{code}


%************************************************************************
%*									*
		External interface
%*									*
%************************************************************************

\begin{code}
tcLetPat :: TcSigFun -> LetBndrSpec
      	 -> LPat Name -> TcSigmaType 
     	 -> TcM a
      	 -> TcM (LPat TcId, a)
tcLetPat sig_fn no_gen pat pat_ty thing_inside
  = tc_lpat pat pat_ty penv thing_inside 
  where
    penv = PE { pe_lazy = True
              , pe_ctxt = LetPat sig_fn no_gen }

-----------------
tcPats :: HsMatchContext Name
       -> [LPat Name]		 -- Patterns,
       -> [TcSigmaType]	         --   and their types
       -> TcM a                  --   and the checker for the body
       -> TcM ([LPat TcId], a)

-- This is the externally-callable wrapper function
-- Typecheck the patterns, extend the environment to bind the variables,
-- do the thing inside, use any existentially-bound dictionaries to 
-- discharge parts of the returning LIE, and deal with pattern type
-- signatures

--   1. Initialise the PatState
--   2. Check the patterns
--   3. Check the body
--   4. Check that no existentials escape

tcPats ctxt pats pat_tys thing_inside
  = tc_lpats penv pats pat_tys thing_inside
  where
    penv = PE { pe_lazy = False, pe_ctxt = LamPat ctxt }

tcPat :: HsMatchContext Name
      -> LPat Name -> TcSigmaType 
      -> TcM a                 -- Checker for body, given
                               -- its result type
      -> TcM (LPat TcId, a)
tcPat ctxt pat pat_ty thing_inside
  = tc_lpat pat pat_ty penv thing_inside
  where
    penv = PE { pe_lazy = False, pe_ctxt = LamPat ctxt }
   

-----------------
data PatEnv
  = PE { pe_lazy :: Bool	-- True <=> lazy context, so no existentials allowed
       , pe_ctxt :: PatCtxt   	-- Context in which the whole pattern appears
       }

data PatCtxt
  = LamPat   -- Used for lambdas, case etc
       (HsMatchContext Name) 

  | LetPat   -- Used only for let(rec) bindings
    	     -- See Note [Let binders]
       TcSigFun        -- Tells type sig if any
       LetBndrSpec     -- True <=> no generalisation of this let

data LetBndrSpec 
  = LetLclBndr		  -- The binder is just a local one;
    			  -- an AbsBinds will provide the global version

  | LetGblBndr TcPragFun  -- There isn't going to be an AbsBinds;
    	       		  -- here is the inline-pragma information

makeLazy :: PatEnv -> PatEnv
makeLazy penv = penv { pe_lazy = True }

patSigCtxt :: PatEnv -> UserTypeCtxt
patSigCtxt (PE { pe_ctxt = LetPat {} }) = BindPatSigCtxt
patSigCtxt (PE { pe_ctxt = LamPat {} }) = LamPatSigCtxt

---------------
type TcPragFun = Name -> [LSig Name]
type TcSigFun  = Name -> Maybe TcSigInfo

data TcSigInfo
  = TcSigInfo {
        sig_id     :: TcId,         --  *Polymorphic* binder for this value...

        sig_scoped :: [Name],	    -- Scoped type variables
		-- 1-1 correspondence with a prefix of sig_tvs
		-- However, may be fewer than sig_tvs; 
		-- see Note [More instantiated than scoped]
        sig_tvs    :: [TcTyVar],    -- Instantiated type variables
                                    -- See Note [Instantiate sig]

        sig_theta  :: TcThetaType,  -- Instantiated theta

        sig_tau    :: TcSigmaType,  -- Instantiated tau
		      		    -- See Note [sig_tau may be polymorphic]

        sig_loc    :: SrcSpan       -- The location of the signature
    }

instance Outputable TcSigInfo where
    ppr (TcSigInfo { sig_id = id, sig_tvs = tyvars, sig_theta = theta, sig_tau = tau})
        = ppr id <+> ptext (sLit "::") <+> ppr tyvars <+> pprThetaArrowTy theta <+> ppr tau
\end{code}

Note [sig_tau may be polymorphic]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Note that "sig_tau" might actually be a polymorphic type,
if the original function had a signature like
   forall a. Eq a => forall b. Ord b => ....
But that's ok: tcMatchesFun (called by tcRhs) can deal with that
It happens, too!  See Note [Polymorphic methods] in TcClassDcl.

Note [Let binders]
~~~~~~~~~~~~~~~~~~
eg   x :: Int
     y :: Bool
     (x,y) = e

...more notes to add here..


Note [Existential check]
~~~~~~~~~~~~~~~~~~~~~~~~
Lazy patterns can't bind existentials.  They arise in two ways:
  * Let bindings      let { C a b = e } in b
  * Twiddle patterns  f ~(C a b) = e
The pe_lazy field of PatEnv says whether we are inside a lazy
pattern (perhaps deeply)

If we aren't inside a lazy pattern then we can bind existentials,
but we need to be careful about "extra" tyvars. Consider
    (\C x -> d) : pat_ty -> res_ty
When looking for existential escape we must check that the existential
bound by C don't unify with the free variables of pat_ty, OR res_ty
(or of course the environment).   Hence we need to keep track of the 
res_ty free vars.


%************************************************************************
%*									*
		Binders
%*									*
%************************************************************************

\begin{code}
tcPatBndr :: PatEnv -> Name -> TcSigmaType -> TcM (TcCoercion, TcId)
-- (coi, xp) = tcPatBndr penv x pat_ty
-- Then coi : pat_ty ~ typeof(xp)
--
tcPatBndr (PE { pe_ctxt = LetPat lookup_sig no_gen}) bndr_name pat_ty
  | Just sig <- lookup_sig bndr_name
  = do { bndr_id <- newSigLetBndr no_gen bndr_name sig
       ; co <- unifyPatType (idType bndr_id) pat_ty
       ; return (co, bndr_id) }
      
  | otherwise
  = do { bndr_id <- newNoSigLetBndr no_gen bndr_name pat_ty
       ; return (mkTcReflCo pat_ty, bndr_id) }

tcPatBndr (PE { pe_ctxt = _lam_or_proc }) bndr_name pat_ty
  = do { bndr <- mkLocalBinder bndr_name pat_ty
       ; return (mkTcReflCo pat_ty, bndr) }

------------
newSigLetBndr :: LetBndrSpec -> Name -> TcSigInfo -> TcM TcId
newSigLetBndr LetLclBndr name sig
  = do { mono_name <- newLocalName name
       ; mkLocalBinder mono_name (sig_tau sig) }
newSigLetBndr (LetGblBndr prags) name sig
  = addInlinePrags (sig_id sig) (prags name)

------------
newNoSigLetBndr :: LetBndrSpec -> Name -> TcType -> TcM TcId
-- In the polymorphic case (no_gen = False), generate a "monomorphic version" 
--    of the Id; the original name will be bound to the polymorphic version
--    by the AbsBinds
-- In the monomorphic case there is no AbsBinds, and we use the original
--    name directly
newNoSigLetBndr LetLclBndr name ty 
  =do  { mono_name <- newLocalName name
       ; mkLocalBinder mono_name ty }
newNoSigLetBndr (LetGblBndr prags) name ty 
  = do { id <- mkLocalBinder name ty
       ; addInlinePrags id (prags name) }

----------
addInlinePrags :: TcId -> [LSig Name] -> TcM TcId
addInlinePrags poly_id prags
  = tc_inl inl_sigs
  where
    inl_sigs = filter isInlineLSig prags
    tc_inl [] = return poly_id
    tc_inl (L loc (InlineSig _ prag) : other_inls)
       = do { unless (null other_inls) (setSrcSpan loc warn_dup_inline)
            ; return (poly_id `setInlinePragma` prag) }
    tc_inl _ = panic "tc_inl"

    warn_dup_inline = warnPrags poly_id inl_sigs $
                      ptext (sLit "Duplicate INLINE pragmas for")

warnPrags :: Id -> [LSig Name] -> SDoc -> TcM ()
warnPrags id bad_sigs herald
  = addWarnTc (hang (herald <+> quotes (ppr id))
                  2 (ppr_sigs bad_sigs))
  where
    ppr_sigs sigs = vcat (map (ppr . getLoc) sigs)

-----------------
mkLocalBinder :: Name -> TcType -> TcM TcId
mkLocalBinder name ty
  = do { checkUnboxedTuple ty $ 
            ptext (sLit "The variable") <+> quotes (ppr name)
       ; return (Id.mkLocalId name ty) }

checkUnboxedTuple :: TcType -> SDoc -> TcM ()
-- Check for an unboxed tuple type
--      f = (# True, False #)
-- Zonk first just in case it's hidden inside a meta type variable
-- (This shows up as a (more obscure) kind error 
--  in the 'otherwise' case of tcMonoBinds.)
checkUnboxedTuple ty what
  = do { zonked_ty <- zonkTcTypeCarefully ty
       ; checkTc (not (isUnboxedTupleType zonked_ty))
                 (unboxedTupleErr what zonked_ty) }

-------------------
{- Only needed if we re-add Method constraints 
bindInstsOfPatId :: TcId -> TcM a -> TcM (a, TcEvBinds)
bindInstsOfPatId id thing_inside
  | not (isOverloadedTy (idType id))
  = do { res <- thing_inside; return (res, emptyTcEvBinds) }
  | otherwise
  = do	{ (res, lie) <- captureConstraints thing_inside
	; binds <- bindLocalMethods lie [id]
	; return (res, binds) }
-}
\end{code}

Note [Polymorphism and pattern bindings]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
When is_mono holds we are not generalising
But the signature can still be polymoprhic!
     data T = MkT (forall a. a->a)
     x :: forall a. a->a
     MkT x = <rhs>
So the no_gen flag decides whether the pattern-bound variables should
have exactly the type in the type signature (when not generalising) or
the instantiated version (when generalising)

%************************************************************************
%*									*
		The main worker functions
%*									*
%************************************************************************

Note [Nesting]
~~~~~~~~~~~~~~
tcPat takes a "thing inside" over which the pattern scopes.  This is partly
so that tcPat can extend the environment for the thing_inside, but also 
so that constraints arising in the thing_inside can be discharged by the
pattern.

This does not work so well for the ErrCtxt carried by the monad: we don't
want the error-context for the pattern to scope over the RHS. 
Hence the getErrCtxt/setErrCtxt stuff in tcMultiple

\begin{code}
--------------------
type Checker inp out =  forall r.
			  inp
		       -> PatEnv
		       -> TcM r
		       -> TcM (out, r)

tcMultiple :: Checker inp out -> Checker [inp] [out]
tcMultiple tc_pat args penv thing_inside
  = do	{ err_ctxt <- getErrCtxt
	; let loop _ []
		= do { res <- thing_inside
		     ; return ([], res) }

	      loop penv (arg:args)
		= do { (p', (ps', res)) 
				<- tc_pat arg penv $ 
				   setErrCtxt err_ctxt $
				   loop penv args
		-- setErrCtxt: restore context before doing the next pattern
		-- See note [Nesting] above
				
		     ; return (p':ps', res) }

	; loop penv args }

--------------------
tc_lpat :: LPat Name 
	-> TcSigmaType
	-> PatEnv
	-> TcM a
	-> TcM (LPat TcId, a)
tc_lpat (L span pat) pat_ty penv thing_inside
  = setSrcSpan span $
    do	{ (pat', res) <- maybeWrapPatCtxt pat (tc_pat penv pat pat_ty)
                                          thing_inside
	; return (L span pat', res) }

tc_lpats :: PatEnv
	 -> [LPat Name] -> [TcSigmaType]
       	 -> TcM a	
       	 -> TcM ([LPat TcId], a)
tc_lpats penv pats tys thing_inside 
  =  tcMultiple (\(p,t) -> tc_lpat p t) 
                (zipEqual "tc_lpats" pats tys)
                penv thing_inside 

--------------------
tc_pat	:: PatEnv
        -> Pat Name 
        -> TcSigmaType	-- Fully refined result type
        -> TcM a		-- Thing inside
        -> TcM (Pat TcId, 	-- Translated pattern
                a)		-- Result of thing inside

tc_pat penv (VarPat name) pat_ty thing_inside
  = do	{ (co, id) <- tcPatBndr penv name pat_ty
        ; res <- tcExtendIdEnv1 name id thing_inside
        ; return (mkHsWrapPatCo co (VarPat id) pat_ty, res) }

tc_pat penv (ParPat pat) pat_ty thing_inside
  = do	{ (pat', res) <- tc_lpat pat pat_ty penv thing_inside
	; return (ParPat pat', res) }

tc_pat penv (BangPat pat) pat_ty thing_inside
  = do	{ (pat', res) <- tc_lpat pat pat_ty penv thing_inside
	; return (BangPat pat', res) }

tc_pat penv lpat@(LazyPat pat) pat_ty thing_inside
  = do	{ (pat', (res, pat_ct)) 
		<- tc_lpat pat pat_ty (makeLazy penv) $ 
		   captureConstraints thing_inside
		-- Ignore refined penv', revert to penv

	; emitConstraints pat_ct
	-- captureConstraints/extendConstraints: 
        --   see Note [Hopping the LIE in lazy patterns]

	-- Check there are no unlifted types under the lazy pattern
	; when (any (isUnLiftedType . idType) $ collectPatBinders pat') $
               lazyUnliftedPatErr lpat

	-- Check that the expected pattern type is itself lifted
	; pat_ty' <- newFlexiTyVarTy liftedTypeKind
	; _ <- unifyType pat_ty pat_ty'

	; return (LazyPat pat', res) }

tc_pat _ p@(QuasiQuotePat _) _ _
  = pprPanic "Should never see QuasiQuotePat in type checker" (ppr p)

tc_pat _ (WildPat _) pat_ty thing_inside
  = do	{ checkUnboxedTuple pat_ty $
               ptext (sLit "A wild-card pattern")
        ; res <- thing_inside 
	; return (WildPat pat_ty, res) }

tc_pat penv (AsPat (L nm_loc name) pat) pat_ty thing_inside
  = do	{ (co, bndr_id) <- setSrcSpan nm_loc (tcPatBndr penv name pat_ty)
        ; (pat', res) <- tcExtendIdEnv1 name bndr_id $
			 tc_lpat pat (idType bndr_id) penv thing_inside
	    -- NB: if we do inference on:
	    --		\ (y@(x::forall a. a->a)) = e
	    -- we'll fail.  The as-pattern infers a monotype for 'y', which then
	    -- fails to unify with the polymorphic type for 'x'.  This could 
	    -- perhaps be fixed, but only with a bit more work.
	    --
	    -- If you fix it, don't forget the bindInstsOfPatIds!
	; return (mkHsWrapPatCo co (AsPat (L nm_loc bndr_id) pat') pat_ty, res) }

tc_pat penv vpat@(ViewPat expr pat _) overall_pat_ty thing_inside 
  = do	{ checkUnboxedTuple overall_pat_ty $
               ptext (sLit "The view pattern") <+> ppr vpat

	 -- Morally, expr must have type `forall a1...aN. OPT' -> B` 
         -- where overall_pat_ty is an instance of OPT'.
         -- Here, we infer a rho type for it,
         -- which replaces the leading foralls and constraints
         -- with fresh unification variables.
        ; (expr',expr'_inferred) <- tcInferRho expr

         -- next, we check that expr is coercible to `overall_pat_ty -> pat_ty`
         -- NOTE: this forces pat_ty to be a monotype (because we use a unification 
         -- variable to find it).  this means that in an example like
         -- (view -> f)    where view :: _ -> forall b. b
         -- we will only be able to use view at one instantation in the
         -- rest of the view
	; (expr_co, pat_ty) <- tcInfer $ \ pat_ty -> 
		unifyType expr'_inferred (mkFunTy overall_pat_ty pat_ty)
        
         -- pattern must have pat_ty
        ; (pat', res) <- tc_lpat pat pat_ty penv thing_inside

	; return (ViewPat (mkLHsWrapCo expr_co expr') pat' overall_pat_ty, res) }

-- Type signatures in patterns
-- See Note [Pattern coercions] below
tc_pat penv (SigPatIn pat sig_ty) pat_ty thing_inside
  = do	{ (inner_ty, tv_binds, wrap) <- tcPatSig (patSigCtxt penv) sig_ty pat_ty
	; (pat', res) <- tcExtendTyVarEnv2 tv_binds $
			 tc_lpat pat inner_ty penv thing_inside

        ; return (mkHsWrapPat wrap (SigPatOut pat' inner_ty) pat_ty, res) }

------------------------
-- Lists, tuples, arrays
tc_pat penv (ListPat pats _) pat_ty thing_inside
  = do	{ (coi, elt_ty) <- matchExpectedPatTy matchExpectedListTy pat_ty
        ; (pats', res) <- tcMultiple (\p -> tc_lpat p elt_ty)
				     pats penv thing_inside
 	; return (mkHsWrapPat coi (ListPat pats' elt_ty) pat_ty, res) 
        }

tc_pat penv (PArrPat pats _) pat_ty thing_inside
  = do	{ (coi, elt_ty) <- matchExpectedPatTy matchExpectedPArrTy pat_ty
	; (pats', res) <- tcMultiple (\p -> tc_lpat p elt_ty)
				     pats penv thing_inside 
	; return (mkHsWrapPat coi (PArrPat pats' elt_ty) pat_ty, res)
        }

tc_pat penv (TuplePat pats boxity _) pat_ty thing_inside
  = do	{ let tc = tupleTyCon (boxityNormalTupleSort boxity) (length pats)
        ; (coi, arg_tys) <- matchExpectedPatTy (matchExpectedTyConApp tc) pat_ty
	; (pats', res) <- tc_lpats penv pats arg_tys thing_inside

	-- Under flag control turn a pattern (x,y,z) into ~(x,y,z)
	-- so that we can experiment with lazy tuple-matching.
	-- This is a pretty odd place to make the switch, but
	-- it was easy to do.
	; let pat_ty'          = mkTyConApp tc arg_tys
                                     -- pat_ty /= pat_ty iff coi /= IdCo
              unmangled_result = TuplePat pats' boxity pat_ty'
	      possibly_mangled_result
	        | opt_IrrefutableTuples && 
                  isBoxed boxity            = LazyPat (noLoc unmangled_result)
	        | otherwise		    = unmangled_result

 	; ASSERT( length arg_tys == length pats )      -- Syntactically enforced
	  return (mkHsWrapPat coi possibly_mangled_result pat_ty, res)
        }

------------------------
-- Data constructors
tc_pat penv (ConPatIn con arg_pats) pat_ty thing_inside
  = tcConPat penv con pat_ty arg_pats thing_inside

------------------------
-- Literal patterns
tc_pat _ (LitPat simple_lit) pat_ty thing_inside
  = do	{ let lit_ty = hsLitType simple_lit
	; co <- unifyPatType lit_ty pat_ty
		-- coi is of kind: pat_ty ~ lit_ty
	; res <- thing_inside 
	; return ( mkHsWrapPatCo co (LitPat simple_lit) pat_ty 
                 , res) }

------------------------
-- Overloaded patterns: n, and n+k
tc_pat _ (NPat over_lit mb_neg eq) pat_ty thing_inside
  = do	{ let orig = LiteralOrigin over_lit
	; lit'    <- newOverloadedLit orig over_lit pat_ty
	; eq'     <- tcSyntaxOp orig eq (mkFunTys [pat_ty, pat_ty] boolTy)
	; mb_neg' <- case mb_neg of
			Nothing  -> return Nothing	-- Positive literal
			Just neg -> 	-- Negative literal
					-- The 'negate' is re-mappable syntax
 			    do { neg' <- tcSyntaxOp orig neg (mkFunTy pat_ty pat_ty)
			       ; return (Just neg') }
	; res <- thing_inside 
	; return (NPat lit' mb_neg' eq', res) }

tc_pat penv (NPlusKPat (L nm_loc name) lit ge minus) pat_ty thing_inside
  = do	{ (co, bndr_id) <- setSrcSpan nm_loc (tcPatBndr penv name pat_ty)
        ; let pat_ty' = idType bndr_id
	      orig    = LiteralOrigin lit
	; lit' <- newOverloadedLit orig lit pat_ty'

	-- The '>=' and '-' parts are re-mappable syntax
	; ge'    <- tcSyntaxOp orig ge    (mkFunTys [pat_ty', pat_ty'] boolTy)
	; minus' <- tcSyntaxOp orig minus (mkFunTys [pat_ty', pat_ty'] pat_ty')
        ; let pat' = NPlusKPat (L nm_loc bndr_id) lit' ge' minus'

	-- The Report says that n+k patterns must be in Integral
	-- We may not want this when using re-mappable syntax, though (ToDo?)
	; icls <- tcLookupClass integralClassName
	; instStupidTheta orig [mkClassPred icls [pat_ty']]	
    
	; res <- tcExtendIdEnv1 name bndr_id thing_inside
	; return (mkHsWrapPatCo co pat' pat_ty, res) }

tc_pat _ _other_pat _ _ = panic "tc_pat" 	-- ConPatOut, SigPatOut

----------------
unifyPatType :: TcType -> TcType -> TcM TcCoercion
-- In patterns we want a coercion from the
-- context type (expected) to the actual pattern type
-- But we don't want to reverse the args to unifyType because
-- that controls the actual/expected stuff in error messages
unifyPatType actual_ty expected_ty
  = do { coi <- unifyType actual_ty expected_ty
       ; return (mkTcSymCo coi) }
\end{code}

Note [Hopping the LIE in lazy patterns]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
In a lazy pattern, we must *not* discharge constraints from the RHS
from dictionaries bound in the pattern.  E.g.
	f ~(C x) = 3
We can't discharge the Num constraint from dictionaries bound by
the pattern C!  

So we have to make the constraints from thing_inside "hop around" 
the pattern.  Hence the captureConstraints and emitConstraints.

The same thing ensures that equality constraints in a lazy match
are not made available in the RHS of the match. For example
	data T a where { T1 :: Int -> T Int; ... }
	f :: T a -> Int -> a
	f ~(T1 i) y = y
It's obviously not sound to refine a to Int in the right
hand side, because the arugment might not match T1 at all!

Finally, a lazy pattern should not bind any existential type variables
because they won't be in scope when we do the desugaring


%************************************************************************
%*									*
	Most of the work for constructors is here
	(the rest is in the ConPatIn case of tc_pat)
%*									*
%************************************************************************

[Pattern matching indexed data types]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider the following declarations:

  data family Map k :: * -> *
  data instance Map (a, b) v = MapPair (Map a (Pair b v))

and a case expression

  case x :: Map (Int, c) w of MapPair m -> ...

As explained by [Wrappers for data instance tycons] in MkIds.lhs, the
worker/wrapper types for MapPair are

  $WMapPair :: forall a b v. Map a (Map a b v) -> Map (a, b) v
  $wMapPair :: forall a b v. Map a (Map a b v) -> :R123Map a b v

So, the type of the scrutinee is Map (Int, c) w, but the tycon of MapPair is
:R123Map, which means the straight use of boxySplitTyConApp would give a type
error.  Hence, the smart wrapper function boxySplitTyConAppWithFamily calls
boxySplitTyConApp with the family tycon Map instead, which gives us the family
type list {(Int, c), w}.  To get the correct split for :R123Map, we need to
unify the family type list {(Int, c), w} with the instance types {(a, b), v}
(provided by tyConFamInst_maybe together with the family tycon).  This
unification yields the substitution [a -> Int, b -> c, v -> w], which gives us
the split arguments for the representation tycon :R123Map as {Int, c, w}

In other words, boxySplitTyConAppWithFamily implicitly takes the coercion 

  Co123Map a b v :: {Map (a, b) v ~ :R123Map a b v}

moving between representation and family type into account.  To produce type
correct Core, this coercion needs to be used to case the type of the scrutinee
from the family to the representation type.  This is achieved by
unwrapFamInstScrutinee using a CoPat around the result pattern.

Now it might appear seem as if we could have used the previous GADT type
refinement infrastructure of refineAlt and friends instead of the explicit
unification and CoPat generation.  However, that would be wrong.  Why?  The
whole point of GADT refinement is that the refinement is local to the case
alternative.  In contrast, the substitution generated by the unification of
the family type list and instance types needs to be propagated to the outside.
Imagine that in the above example, the type of the scrutinee would have been
(Map x w), then we would have unified {x, w} with {(a, b), v}, yielding the
substitution [x -> (a, b), v -> w].  In contrast to GADT matching, the
instantiation of x with (a, b) must be global; ie, it must be valid in *all*
alternatives of the case expression, whereas in the GADT case it might vary
between alternatives.

RIP GADT refinement: refinements have been replaced by the use of explicit
equality constraints that are used in conjunction with implication constraints
to express the local scope of GADT refinements.

\begin{code}
--	Running example:
-- MkT :: forall a b c. (a~[b]) => b -> c -> T a
-- 	 with scrutinee of type (T ty)

tcConPat :: PatEnv -> Located Name 
	 -> TcRhoType  	       	-- Type of the pattern
	 -> HsConPatDetails Name -> TcM a
	 -> TcM (Pat TcId, a)
tcConPat penv (L con_span con_name) pat_ty arg_pats thing_inside
  = do	{ data_con <- tcLookupDataCon con_name
	; let tycon = dataConTyCon data_con
         	  -- For data families this is the representation tycon
	      (univ_tvs, ex_tvs, eq_spec, theta, arg_tys, _)
                = dataConFullSig data_con

	  -- Instantiate the constructor type variables [a->ty]
	  -- This may involve doing a family-instance coercion, 
	  -- and building a wrapper 
	; (wrap, ctxt_res_tys) <- matchExpectedPatTy (matchExpectedConTy tycon) pat_ty

	  -- Add the stupid theta
	; setSrcSpan con_span $ addDataConStupidTheta data_con ctxt_res_tys

	; checkExistentials ex_tvs penv 
        ; (tenv, ex_tvs') <- tcInstSuperSkolTyVarsX
                               (zipTopTvSubst univ_tvs ctxt_res_tys) ex_tvs
                     -- Get location from monad, not from ex_tvs

        ; let pat_ty' = mkTyConApp tycon ctxt_res_tys
	      -- pat_ty' is type of the actual constructor application
              -- pat_ty' /= pat_ty iff coi /= IdCo
              
	      arg_tys' = substTys tenv arg_tys

	; if null ex_tvs && null eq_spec && null theta
	  then do { -- The common case; no class bindings etc 
                    -- (see Note [Arrows and patterns])
		    (arg_pats', res) <- tcConArgs data_con arg_tys' 
						  arg_pats penv thing_inside
		  ; let res_pat = ConPatOut { pat_con = L con_span data_con, 
			            	      pat_tvs = [], pat_dicts = [], 
                                              pat_binds = emptyTcEvBinds,
					      pat_args = arg_pats', 
                                              pat_ty = pat_ty' }

		  ; return (mkHsWrapPat wrap res_pat pat_ty, res) }

	  else do   -- The general case, with existential, 
                    -- and local equality constraints
	{ let theta'   = substTheta tenv (eqSpecPreds eq_spec ++ theta)
                           -- order is *important* as we generate the list of
                           -- dictionary binders from theta'
	      no_equalities = not (any isEqPred theta')
              skol_info = case pe_ctxt penv of
                            LamPat mc -> PatSkol data_con mc
                            LetPat {} -> UnkSkol -- Doesn't matter
 
        ; gadts_on <- xoptM Opt_GADTs
	; checkTc (no_equalities || gadts_on)
	  	  (ptext (sLit "A pattern match on a GADT requires -XGADTs"))
		  -- Trac #2905 decided that a *pattern-match* of a GADT
		  -- should require the GADT language flag

        ; given <- newEvVars theta'
        ; (ev_binds, (arg_pats', res))
	     <- checkConstraints skol_info ex_tvs' given $
                tcConArgs data_con arg_tys' arg_pats penv thing_inside

        ; let res_pat = ConPatOut { pat_con   = L con_span data_con, 
			            pat_tvs   = ex_tvs',
			            pat_dicts = given,
			            pat_binds = ev_binds,
			            pat_args  = arg_pats', 
                                    pat_ty    = pat_ty' }
	; return (mkHsWrapPat wrap res_pat pat_ty, res)
	} }

----------------------------
matchExpectedPatTy :: (TcRhoType -> TcM (TcCoercion, a))
                    -> TcRhoType -> TcM (HsWrapper, a) 
-- See Note [Matching polytyped patterns]
-- Returns a wrapper : pat_ty ~ inner_ty
matchExpectedPatTy inner_match pat_ty
  | null tvs && null theta
  = do { (co, res) <- inner_match pat_ty
       ; return (coToHsWrapper (mkTcSymCo co), res) }
       	 -- The Sym is because the inner_match returns a coercion
	 -- that is the other way round to matchExpectedPatTy

  | otherwise
  = do { (_, tys, subst) <- tcInstTyVars tvs
       ; wrap1 <- instCall PatOrigin tys (substTheta subst theta)
       ; (wrap2, arg_tys) <- matchExpectedPatTy inner_match (TcType.substTy subst tau)
       ; return (wrap2 <.> wrap1 , arg_tys) }
  where
    (tvs, theta, tau) = tcSplitSigmaTy pat_ty

----------------------------
matchExpectedConTy :: TyCon  	 -- The TyCon that this data 
		    		 -- constructor actually returns
		   -> TcRhoType  -- The type of the pattern
		   -> TcM (TcCoercion, [TcSigmaType])
-- See Note [Matching constructor patterns]
-- Returns a coercion : T ty1 ... tyn ~ pat_ty
-- This is the same way round as matchExpectedListTy etc
-- but the other way round to matchExpectedPatTy
matchExpectedConTy data_tc pat_ty
  | Just (fam_tc, fam_args, co_tc) <- tyConFamInstSig_maybe data_tc
    	 -- Comments refer to Note [Matching constructor patterns]
     	 -- co_tc :: forall a. T [a] ~ T7 a
  = do { (_, tys, subst) <- tcInstTyVars (tyConTyVars data_tc)
       	     -- tys = [ty1,ty2]

       ; co1 <- unifyType (mkTyConApp fam_tc (substTys subst fam_args)) pat_ty
       	     -- co1 : T (ty1,ty2) ~ pat_ty

       ; let co2 = mkTcAxInstCo co_tc tys
       	     -- co2 : T (ty1,ty2) ~ T7 ty1 ty2

       ; return (mkTcSymCo co2 `mkTcTransCo` co1, tys) }

  | otherwise
  = matchExpectedTyConApp data_tc pat_ty
       	     -- coi : T tys ~ pat_ty
\end{code}

Note [Matching constructor patterns]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Suppose (coi, tys) = matchExpectedConType data_tc pat_ty

 * In the simple case, pat_ty = tc tys

 * If pat_ty is a polytype, we want to instantiate it
   This is like part of a subsumption check.  Eg
      f :: (forall a. [a]) -> blah
      f [] = blah

 * In a type family case, suppose we have
          data family T a
          data instance T (p,q) = A p | B q
       Then we'll have internally generated
              data T7 p q = A p | B q
              axiom coT7 p q :: T (p,q) ~ T7 p q
 
       So if pat_ty = T (ty1,ty2), we return (coi, [ty1,ty2]) such that
           coi = coi2 . coi1 : T7 t ~ pat_ty
           coi1 : T (ty1,ty2) ~ pat_ty
           coi2 : T7 ty1 ty2 ~ T (ty1,ty2)

   For families we do all this matching here, not in the unifier,
   because we never want a whisper of the data_tycon to appear in
   error messages; it's a purely internal thing

\begin{code}
tcConArgs :: DataCon -> [TcSigmaType]
	  -> Checker (HsConPatDetails Name) (HsConPatDetails Id)

tcConArgs data_con arg_tys (PrefixCon arg_pats) penv thing_inside
  = do	{ checkTc (con_arity == no_of_args)	-- Check correct arity
		  (arityErr "Constructor" data_con con_arity no_of_args)
	; let pats_w_tys = zipEqual "tcConArgs" arg_pats arg_tys
	; (arg_pats', res) <- tcMultiple tcConArg pats_w_tys
					      penv thing_inside 
	; return (PrefixCon arg_pats', res) }
  where
    con_arity  = dataConSourceArity data_con
    no_of_args = length arg_pats

tcConArgs data_con arg_tys (InfixCon p1 p2) penv thing_inside
  = do	{ checkTc (con_arity == 2)	-- Check correct arity
	 	  (arityErr "Constructor" data_con con_arity 2)
	; let [arg_ty1,arg_ty2] = arg_tys	-- This can't fail after the arity check
	; ([p1',p2'], res) <- tcMultiple tcConArg [(p1,arg_ty1),(p2,arg_ty2)]
					      penv thing_inside
	; return (InfixCon p1' p2', res) }
  where
    con_arity  = dataConSourceArity data_con

tcConArgs data_con arg_tys (RecCon (HsRecFields rpats dd)) penv thing_inside
  = do	{ (rpats', res) <- tcMultiple tc_field rpats penv thing_inside
	; return (RecCon (HsRecFields rpats' dd), res) }
  where
    tc_field :: Checker (HsRecField FieldLabel (LPat Name)) (HsRecField TcId (LPat TcId))
    tc_field (HsRecField field_lbl pat pun) penv thing_inside
      = do { (sel_id, pat_ty) <- wrapLocFstM find_field_ty field_lbl
	   ; (pat', res) <- tcConArg (pat, pat_ty) penv thing_inside
	   ; return (HsRecField sel_id pat' pun, res) }

    find_field_ty :: FieldLabel -> TcM (Id, TcType)
    find_field_ty field_lbl
	= case [ty | (f,ty) <- field_tys, f == field_lbl] of

		-- No matching field; chances are this field label comes from some
		-- other record type (or maybe none).  As well as reporting an
		-- error we still want to typecheck the pattern, principally to
		-- make sure that all the variables it binds are put into the
		-- environment, else the type checker crashes later:
		--	f (R { foo = (a,b) }) = a+b
		-- If foo isn't one of R's fields, we don't want to crash when
		-- typechecking the "a+b".
	   [] -> do { addErrTc (badFieldCon data_con field_lbl)
		    ; bogus_ty <- newFlexiTyVarTy liftedTypeKind
		    ; return (error "Bogus selector Id", bogus_ty) }

		-- The normal case, when the field comes from the right constructor
	   (pat_ty : extras) -> 
		ASSERT( null extras )
		do { sel_id <- tcLookupField field_lbl
		   ; return (sel_id, pat_ty) }

    field_tys :: [(FieldLabel, TcType)]
    field_tys = zip (dataConFieldLabels data_con) arg_tys
	-- Don't use zipEqual! If the constructor isn't really a record, then
	-- dataConFieldLabels will be empty (and each field in the pattern
	-- will generate an error below).

tcConArg :: Checker (LPat Name, TcSigmaType) (LPat Id)
tcConArg (arg_pat, arg_ty) penv thing_inside
  = tc_lpat arg_pat arg_ty penv thing_inside
\end{code}

\begin{code}
addDataConStupidTheta :: DataCon -> [TcType] -> TcM ()
-- Instantiate the "stupid theta" of the data con, and throw 
-- the constraints into the constraint set
addDataConStupidTheta data_con inst_tys
  | null stupid_theta = return ()
  | otherwise	      = instStupidTheta origin inst_theta
  where
    origin = OccurrenceOf (dataConName data_con)
	-- The origin should always report "occurrence of C"
	-- even when C occurs in a pattern
    stupid_theta = dataConStupidTheta data_con
    tenv = mkTopTvSubst (dataConUnivTyVars data_con `zip` inst_tys)
    	 -- NB: inst_tys can be longer than the univ tyvars
	 --     because the constructor might have existentials
    inst_theta = substTheta tenv stupid_theta
\end{code}

Note [Arrows and patterns]
~~~~~~~~~~~~~~~~~~~~~~~~~~
(Oct 07) Arrow noation has the odd property that it involves 
"holes in the scope". For example:
  expr :: Arrow a => a () Int
  expr = proc (y,z) -> do
          x <- term -< y
          expr' -< x

Here the 'proc (y,z)' binding scopes over the arrow tails but not the
arrow body (e.g 'term').  As things stand (bogusly) all the
constraints from the proc body are gathered together, so constraints
from 'term' will be seen by the tcPat for (y,z).  But we must *not*
bind constraints from 'term' here, becuase the desugarer will not make
these bindings scope over 'term'.

The Right Thing is not to confuse these constraints together. But for
now the Easy Thing is to ensure that we do not have existential or
GADT constraints in a 'proc', and to short-cut the constraint
simplification for such vanilla patterns so that it binds no
constraints. Hence the 'fast path' in tcConPat; but it's also a good
plan for ordinary vanilla patterns to bypass the constraint
simplification step.

%************************************************************************
%*									*
		Note [Pattern coercions]
%*									*
%************************************************************************

In principle, these program would be reasonable:
	
	f :: (forall a. a->a) -> Int
	f (x :: Int->Int) = x 3

	g :: (forall a. [a]) -> Bool
	g [] = True

In both cases, the function type signature restricts what arguments can be passed
in a call (to polymorphic ones).  The pattern type signature then instantiates this
type.  For example, in the first case,  (forall a. a->a) <= Int -> Int, and we
generate the translated term
	f = \x' :: (forall a. a->a).  let x = x' Int in x 3

From a type-system point of view, this is perfectly fine, but it's *very* seldom useful.
And it requires a significant amount of code to implement, becuase we need to decorate
the translated pattern with coercion functions (generated from the subsumption check 
by tcSub).  

So for now I'm just insisting on type *equality* in patterns.  No subsumption. 

Old notes about desugaring, at a time when pattern coercions were handled:

A SigPat is a type coercion and must be handled one at at time.  We can't
combine them unless the type of the pattern inside is identical, and we don't
bother to check for that.  For example:

	data T = T1 Int | T2 Bool
	f :: (forall a. a -> a) -> T -> t
	f (g::Int->Int)   (T1 i) = T1 (g i)
	f (g::Bool->Bool) (T2 b) = T2 (g b)

We desugar this as follows:

	f = \ g::(forall a. a->a) t::T ->
	    let gi = g Int
	    in case t of { T1 i -> T1 (gi i)
			   other ->
	    let	gb = g Bool
	    in case t of { T2 b -> T2 (gb b)
			   other -> fail }}

Note that we do not treat the first column of patterns as a
column of variables, because the coerced variables (gi, gb)
would be of different types.  So we get rather grotty code.
But I don't think this is a common case, and if it was we could
doubtless improve it.

Meanwhile, the strategy is:
	* treat each SigPat coercion (always non-identity coercions)
		as a separate block
	* deal with the stuff inside, and then wrap a binding round
		the result to bind the new variable (gi, gb, etc)


%************************************************************************
%*									*
\subsection{Errors and contexts}
%*									*
%************************************************************************

{-   This was used to improve the error message from 
     an existential escape. Need to think how to do this.

sigPatCtxt :: [LPat Var] -> [Var] -> [TcType] -> TcType -> TidyEnv
           -> TcM (TidyEnv, SDoc)
sigPatCtxt pats bound_tvs pat_tys body_ty tidy_env 
  = do	{ pat_tys' <- mapM zonkTcType pat_tys
	; body_ty' <- zonkTcType body_ty
	; let (env1,  tidy_tys)    = tidyOpenTypes tidy_env (map idType show_ids)
	      (env2, tidy_pat_tys) = tidyOpenTypes env1 pat_tys'
	      (env3, tidy_body_ty) = tidyOpenType  env2 body_ty'
	; return (env3,
		 sep [ptext (sLit "When checking an existential match that binds"),
		      nest 2 (vcat (zipWith ppr_id show_ids tidy_tys)),
		      ptext (sLit "The pattern(s) have type(s):") <+> vcat (map ppr tidy_pat_tys),
		      ptext (sLit "The body has type:") <+> ppr tidy_body_ty
		]) }
  where
    bound_ids = collectPatsBinders pats
    show_ids = filter is_interesting bound_ids
    is_interesting id = any (`elemVarSet` varTypeTyVars id) bound_tvs

    ppr_id id ty = ppr id <+> dcolon <+> ppr ty
	-- Don't zonk the types so we get the separate, un-unified versions
-}

\begin{code}
maybeWrapPatCtxt :: Pat Name -> (TcM a -> TcM b) -> TcM a -> TcM b
-- Not all patterns are worth pushing a context
maybeWrapPatCtxt pat tcm thing_inside 
  | not (worth_wrapping pat) = tcm thing_inside
  | otherwise                = addErrCtxt msg $ tcm $ popErrCtxt thing_inside
    			       -- Remember to pop before doing thing_inside
  where
   worth_wrapping (VarPat {}) = False
   worth_wrapping (ParPat {}) = False
   worth_wrapping (AsPat {})  = False
   worth_wrapping _  	      = True
   msg = hang (ptext (sLit "In the pattern:")) 2 (ppr pat)

-----------------------------------------------
checkExistentials :: [TyVar] -> PatEnv -> TcM ()
	  -- See Note [Arrows and patterns]
checkExistentials [] _                                 = return ()
checkExistentials _ (PE { pe_ctxt = LetPat {}})        = failWithTc existentialLetPat
checkExistentials _ (PE { pe_ctxt = LamPat ProcExpr }) = failWithTc existentialProcPat
checkExistentials _ (PE { pe_lazy = True })            = failWithTc existentialLazyPat
checkExistentials _ _                                  = return ()

existentialLazyPat :: SDoc
existentialLazyPat
  = hang (ptext (sLit "An existential or GADT data constructor cannot be used"))
       2 (ptext (sLit "inside a lazy (~) pattern"))

existentialProcPat :: SDoc
existentialProcPat 
  = ptext (sLit "Proc patterns cannot use existential or GADT data constructors")

existentialLetPat :: SDoc
existentialLetPat
  = vcat [text "My brain just exploded",
	  text "I can't handle pattern bindings for existential or GADT data constructors.",
	  text "Instead, use a case-expression, or do-notation, to unpack the constructor."]

badFieldCon :: DataCon -> Name -> SDoc
badFieldCon con field
  = hsep [ptext (sLit "Constructor") <+> quotes (ppr con),
	  ptext (sLit "does not have field"), quotes (ppr field)]

polyPatSig :: TcType -> SDoc
polyPatSig sig_ty
  = hang (ptext (sLit "Illegal polymorphic type signature in pattern:"))
       2 (ppr sig_ty)

lazyUnliftedPatErr :: OutputableBndr name => Pat name -> TcM ()
lazyUnliftedPatErr pat
  = failWithTc $
    hang (ptext (sLit "A lazy (~) pattern cannot contain unlifted types:"))
       2 (ppr pat)

unboxedTupleErr :: SDoc -> Type -> SDoc
unboxedTupleErr what ty
  = hang (what <+> ptext (sLit "cannot have an unboxed tuple type:"))
       2 (ppr ty)
\end{code}
