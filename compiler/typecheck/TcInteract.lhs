\begin{code}
{-# OPTIONS -fno-warn-tabs #-}
-- The above warning supression flag is a temporary kludge.
-- While working on this module you are encouraged to remove it and
-- detab the module (please do the detabbing in a separate patch). See
--     http://hackage.haskell.org/trac/ghc/wiki/Commentary/CodingStyle#TabsvsSpaces
-- for details

module TcInteract ( 
     solveInteractWanted, -- Solves [WantedEvVar]
     solveInteractGiven,  -- Solves [EvVar],GivenLoc
     solveInteractCts,    -- Solves [Cts]
  ) where  

#include "HsVersions.h"


import BasicTypes ()
import TcCanonical
import VarSet
import Type
import Unify

import Id 
import Var
import VarEnv ( ) -- unitVarEnv, mkInScopeSet

import TcType

import Class
import TyCon
import Name
import IParam

import FunDeps

import TcEvidence
import Outputable

import TcRnTypes
import TcErrors
import TcSMonad
import Maybes( orElse )
import Bag

import Control.Monad ( foldM )
import TrieMap

import VarEnv
import qualified Data.Traversable as Traversable

import Control.Monad( when )
import Pair ( pSnd )
import UniqFM
import FastString ( sLit ) 
import DynFlags
\end{code}
**********************************************************************
*                                                                    * 
*                      Main Interaction Solver                       *
*                                                                    *
**********************************************************************

Note [Basic Simplifier Plan] 
~~~~~~~~~~~~~~~~~~~~~~~~~~~~

1. Pick an element from the WorkList if there exists one with depth 
   less thanour context-stack depth. 

2. Run it down the 'stage' pipeline. Stages are: 
      - canonicalization
      - inert reactions
      - spontaneous reactions
      - top-level intreactions
   Each stage returns a StopOrContinue and may have sideffected 
   the inerts or worklist.
  
   The threading of the stages is as follows: 
      - If (Stop) is returned by a stage then we start again from Step 1. 
      - If (ContinueWith ct) is returned by a stage, we feed 'ct' on to 
        the next stage in the pipeline. 
4. If the element has survived (i.e. ContinueWith x) the last stage 
   then we add him in the inerts and jump back to Step 1.

If in Step 1 no such element exists, we have exceeded our context-stack 
depth and will simply fail.
\begin{code}

solveInteractCts :: [Ct] -> TcS ()
solveInteractCts cts 
  = do { evvar_cache <- getTcSEvVarCacheMap
       ; (cts_thinner, new_evvar_cache) <- add_cts_in_cache evvar_cache cts
       ; traceTcS "solveInteractCts" (vcat [ text "cts_original =" <+> ppr cts, 
                                             text "cts_thinner  =" <+> ppr cts_thinner
                                           ])
       ; setTcSEvVarCacheMap new_evvar_cache 
       ; updWorkListTcS (appendWorkListCt cts_thinner) >> solveInteract }
 
  where
    add_cts_in_cache evvar_cache cts
      = do { ctxt <- getTcSContext
           ; foldM (solve_or_cache (simplEqsOnly ctxt)) ([],evvar_cache) cts }

    solve_or_cache :: Bool    -- Solve equalities only, not classes etc
                   -> ([Ct],TypeMap (EvVar,CtFlavor))
                   -> Ct
                   -> TcS ([Ct],TypeMap (EvVar,CtFlavor))
    solve_or_cache eqs_only (acc_cts,acc_cache) ct
      | dont_cache eqs_only (classifyPredType pred_ty)
      = return (ct:acc_cts,acc_cache)

      | Just (ev',fl') <- lookupTM pred_ty acc_cache
      , fl' `canSolve` fl
      , isWanted fl
      = do { _ <- setEvBind ev (EvId ev') fl
           ; return (acc_cts,acc_cache) }

      | otherwise -- If it's a given keep it in the work list, even if it exists in the cache!
      = return (ct:acc_cts, alterTM pred_ty (\_ -> Just (ev,fl)) acc_cache)
      where fl = cc_flavor ct
            ev = cc_id ct
            pred_ty = ctPred ct

    dont_cache :: Bool -> PredTree -> Bool
    -- Do not use the cache, not update it, if this is true
    dont_cache _ (IPPred {}) = True    -- IPPreds have subtle shadowing
    dont_cache _ (EqPred ty1 ty2)      -- Report Int ~ Bool errors separately
      | Just tc1 <- tyConAppTyCon_maybe ty1
      , Just tc2 <- tyConAppTyCon_maybe ty2
      , tc1 /= tc2
      = isDecomposableTyCon tc1 && isDecomposableTyCon tc2
      | otherwise = False
    dont_cache eqs_only _ = eqs_only
            -- If we are simplifying equalities only,
            -- do not cache non-equalities
            -- See Note [Simplifying RULE lhs constraints] in TcSimplify

solveInteractGiven :: GivenLoc -> [EvVar] -> TcS () 
solveInteractGiven gloc evs
  = solveInteractCts (map mk_noncan evs)
  where mk_noncan ev = CNonCanonical { cc_id = ev
                                     , cc_flavor = Given gloc GivenOrig 
                                     , cc_depth = 0 }

solveInteractWanted :: [WantedEvVar] -> TcS ()
-- Solve these wanteds along with current inerts and wanteds!
solveInteractWanted wevs
  = solveInteractCts (map mk_noncan wevs) 
  where mk_noncan (EvVarX v w) 
          = CNonCanonical { cc_id = v, cc_flavor = Wanted w, cc_depth = 0 }


-- The main solver loop implements Note [Basic Simplifier Plan]
---------------------------------------------------------------
solveInteract :: TcS ()
-- Returns the final InertSet in TcS, WorkList will be eventually empty.
solveInteract
  = {-# SCC "solveInteract" #-}
    do { dyn_flags <- getDynFlags
       ; let max_depth = ctxtStkDepth dyn_flags
             solve_loop
              = {-# SCC "solve_loop" #-}
                do { sel <- selectNextWorkItem max_depth
                   ; case sel of 
                      NoWorkRemaining     -- Done, successfuly (modulo frozen)
                        -> return ()
                      MaxDepthExceeded ct -- Failure, depth exceeded
                        -> solverDepthErrorTcS (cc_depth ct) [ct]
                      NextWorkItem ct     -- More work, loop around!
                        -> runSolverPipeline thePipeline ct >> solve_loop }
       ; solve_loop }

type WorkItem = Ct
type SimplifierStage = WorkItem -> TcS StopOrContinue

continueWith :: WorkItem -> TcS StopOrContinue
continueWith work_item = return (ContinueWith work_item) 

data SelectWorkItem 
       = NoWorkRemaining      -- No more work left (effectively we're done!)
       | MaxDepthExceeded Ct  -- More work left to do but this constraint has exceeded
                              -- the max subgoal depth and we must stop 
       | NextWorkItem Ct      -- More work left, here's the next item to look at 

selectNextWorkItem :: SubGoalDepth -- Max depth allowed
                   -> TcS SelectWorkItem
selectNextWorkItem max_depth
  = updWorkListTcS_return pick_next
  where 
    pick_next :: WorkList -> (SelectWorkItem, WorkList)
    pick_next wl = case selectWorkItem wl of
                     (Nothing,_) 
                         -> (NoWorkRemaining,wl)           -- No more work
                     (Just ct, new_wl) 
                         | cc_depth ct > max_depth         -- Depth exceeded
                         -> (MaxDepthExceeded ct,new_wl)
                     (Just ct, new_wl) 
                         -> (NextWorkItem ct, new_wl)      -- New workitem and worklist

runSolverPipeline :: [(String,SimplifierStage)] -- The pipeline 
                  -> WorkItem                   -- The work item 
                  -> TcS () 
-- Run this item down the pipeline, leaving behind new work and inerts
runSolverPipeline pipeline workItem 
  = do { initial_is <- getTcSInerts 
       ; traceTcS "Start solver pipeline {" $ 
                  vcat [ ptext (sLit "work item = ") <+> ppr workItem 
                       , ptext (sLit "inerts    = ") <+> ppr initial_is]

       ; final_res  <- run_pipeline pipeline (ContinueWith workItem)

       ; final_is <- getTcSInerts
       ; case final_res of 
           Stop            -> do { traceTcS "End solver pipeline (discharged) }" 
                                       (ptext (sLit "inerts    = ") <+> ppr final_is)
                                 ; return () }
           ContinueWith ct -> do { traceTcS "End solver pipeline (not discharged) }" $
                                       vcat [ ptext (sLit "final_item = ") <+> ppr ct
                                            , ptext (sLit "inerts     = ") <+> ppr final_is]
                                 ; updInertSetTcS ct }
       }
  where run_pipeline :: [(String,SimplifierStage)] -> StopOrContinue -> TcS StopOrContinue
        run_pipeline [] res = return res 
        run_pipeline _ Stop = return Stop 
        run_pipeline ((stg_name,stg):stgs) (ContinueWith ct)
          = do { traceTcS ("runStage " ++ stg_name ++ " {")
                          (text "workitem   = " <+> ppr ct) 
               ; res <- stg ct 
               ; traceTcS ("end stage " ++ stg_name ++ " }") empty
               ; run_pipeline stgs res 
               }
\end{code}

Example 1:
  Inert:   {c ~ d, F a ~ t, b ~ Int, a ~ ty} (all given)
  Reagent: a ~ [b] (given)

React with (c~d)     ==> IR (ContinueWith (a~[b]))  True    []
React with (F a ~ t) ==> IR (ContinueWith (a~[b]))  False   [F [b] ~ t]
React with (b ~ Int) ==> IR (ContinueWith (a~[Int]) True    []

Example 2:
  Inert:  {c ~w d, F a ~g t, b ~w Int, a ~w ty}
  Reagent: a ~w [b]

React with (c ~w d)   ==> IR (ContinueWith (a~[b]))  True    []
React with (F a ~g t) ==> IR (ContinueWith (a~[b]))  True    []    (can't rewrite given with wanted!)
etc.

Example 3:
  Inert:  {a ~ Int, F Int ~ b} (given)
  Reagent: F a ~ b (wanted)

React with (a ~ Int)   ==> IR (ContinueWith (F Int ~ b)) True []
React with (F Int ~ b) ==> IR Stop True []    -- after substituting we re-canonicalize and get nothing

\begin{code}
thePipeline :: [(String,SimplifierStage)]
thePipeline = [ ("canonicalization",        canonicalizationStage)
              , ("spontaneous solve",       spontaneousSolveStage)
              , ("interact with inerts",    interactWithInertsStage)
              , ("top-level reactions",     topReactionsStage) ]
\end{code}


\begin{code}

-- The canonicalization stage, see TcCanonical for details
----------------------------------------------------------
canonicalizationStage :: SimplifierStage
canonicalizationStage = TcCanonical.canonicalize 

\end{code}

*********************************************************************************
*                                                                               * 
                       The spontaneous-solve Stage
*                                                                               *
*********************************************************************************

Note [Efficient Orientation] 
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

There are two cases where we have to be careful about 
orienting equalities to get better efficiency. 

Case 1: In Rewriting Equalities (function rewriteEqLHS) 

    When rewriting two equalities with the same LHS:
          (a)  (tv ~ xi1) 
          (b)  (tv ~ xi2) 
    We have a choice of producing work (xi1 ~ xi2) (up-to the
    canonicalization invariants) However, to prevent the inert items
    from getting kicked out of the inerts first, we prefer to
    canonicalize (xi1 ~ xi2) if (b) comes from the inert set, or (xi2
    ~ xi1) if (a) comes from the inert set.
    
    This choice is implemented using the WhichComesFromInert flag. 

Case 2: Functional Dependencies 
    Again, we should prefer, if possible, the inert variables on the RHS

Case 3: IP improvement work
    We must always rewrite so that the inert type is on the right. 

\begin{code}
spontaneousSolveStage :: SimplifierStage 
spontaneousSolveStage workItem
  = do { mSolve <- trySpontaneousSolve workItem
       ; spont_solve mSolve } 
  where spont_solve SPCantSolve 
          | isCTyEqCan workItem                    -- Unsolved equality
          = do { kickOutRewritableInerts workItem  -- NB: will add workItem in inerts
               ; return Stop }
          | otherwise
          = continueWith workItem
        spont_solve (SPSolved workItem')           -- Post: workItem' must be equality
          = do { bumpStepCountTcS
               ; traceFireTcS (cc_depth workItem) $
                 ptext (sLit "Spontaneous") 
                           <+> parens (ppr (cc_flavor workItem)) <+> ppr workItem

                 -- NB: will add the item in the inerts
               ; kickOutRewritableInerts workItem'
               -- .. and Stop
               ; return Stop }

kickOutRewritableInerts :: Ct -> TcS () 
-- Pre:  ct is a CTyEqCan 
-- Post: The TcS monad is left with the thinner non-rewritable inerts; but which
--       contains the new constraint.
--       The rewritable end up in the worklist
kickOutRewritableInerts ct
  = {-# SCC "kickOutRewritableInerts" #-}
    do { (wl,ieqs) <- {-# SCC "kick_out_rewritable" #-}
                      modifyInertTcS (kick_out_rewritable ct)

       -- Step 1: Rewrite as many of the inert_eqs on the spot! 
       -- NB: if it is a solved constraint just use the cached evidence
       
       ; let ct_coercion = getCtCoercion ct 

       ; new_ieqs <- {-# SCC "rewriteInertEqsFromInertEq" #-}
                     rewriteInertEqsFromInertEq (cc_tyvar ct,ct_coercion, cc_flavor ct) ieqs
       ; modifyInertTcS (\is -> ((), is { inert_eqs = new_ieqs }))

       -- Step 2: Add the new guy in
       ; updInertSetTcS ct

       ; traceTcS "Kick out" (ppr ct $$ ppr wl)
       ; updWorkListTcS (unionWorkList wl) }

rewriteInertEqsFromInertEq :: (TcTyVar, TcCoercion, CtFlavor) -- A new substitution
                           -> TyVarEnv (Ct, TcCoercion)       -- All inert equalities
                           -> TcS (TyVarEnv (Ct,TcCoercion)) -- The new inert equalities
rewriteInertEqsFromInertEq (subst_tv, subst_co, subst_fl) ieqs
-- The goal: traverse the inert equalities and rewrite some of them, dropping some others
-- back to the worklist. This is delicate, see Note [Delicate equality kick-out]
 = do { mieqs <- Traversable.mapM do_one ieqs 
      ; traceTcS "Original inert equalities:" (ppr ieqs)
      ; let flatten_justs elem venv
              | Just (act,aco) <- elem = extendVarEnv venv (cc_tyvar act) (act,aco)
              | otherwise = venv                                     
            final_ieqs = foldVarEnv flatten_justs emptyVarEnv mieqs
      ; traceTcS "Remaining inert equalities:" (ppr final_ieqs)
      ; return final_ieqs }

 where do_one (ct,inert_co)
         | subst_fl `canRewrite` fl && (subst_tv `elemVarSet` tyVarsOfCt ct) 
                                      -- Annoyingly inefficient, but we can't simply check 
                                      -- that isReflCo co because of cached solved ReflCo evidence.
         = if fl `canRewrite` subst_fl then 
               -- If also the inert can rewrite the subst it's totally safe 
               -- to rewrite on the spot
               do { (ct',inert_co') <- rewrite_on_the_spot (ct,inert_co)
                  ; return $ Just (ct',inert_co') }
           else -- We have to throw inert back to worklist for occurs checks 
              do { updWorkListTcS (extendWorkListEq ct)
                 ; return Nothing }
         | otherwise -- Just keep it there
         = return $ Just (ct,inert_co)
         where 
	   -- We have new guy         co : tv ~ something
	   -- and old inert  {wanted} cv : tv' ~ rhs[tv]
	   -- We want to rewrite to
	   --  	      	     {wanted} cv' : tv' ~ rhs[something] 
           --                cv = cv' ; rhs[Sym co]
	   --                  
           rewrite_on_the_spot (ct,_inert_co)
             = do { let rhs' = pSnd (tcCoercionKind co)
                  ; delCachedEvVar ev fl
                  ; evc <- newEqVar fl (mkTyVarTy tv) rhs'
                  ; let ev'   = evc_the_evvar evc
                  ; let evco' = mkTcCoVarCo ev' 
                  ; fl' <- if isNewEvVar evc then
                               do { case fl of 
                                      Wanted {} 
                                        -> setEqBind ev (evco' `mkTcTransCo` mkTcSymCo co) fl
                                      Given {} 
                                        -> setEqBind ev' (mkTcCoVarCo ev `mkTcTransCo` co) fl
                                      Derived {}
                                        -> return fl }
                           else
                               if isWanted fl then 
                                   setEqBind ev (evco' `mkTcTransCo` mkTcSymCo co) fl
                               else return fl
                  ; let ct' = ct { cc_id = ev', cc_flavor = fl', cc_rhs = rhs' }
                  ; return (ct',evco') }
           ev  = cc_id ct
           fl  = cc_flavor ct
           tv  = cc_tyvar ct
           rhs = cc_rhs ct
           co  = liftTcCoSubstWith [subst_tv] [subst_co] rhs

kick_out_rewritable :: Ct -> InertSet -> ((WorkList,TyVarEnv (Ct,TcCoercion)), InertSet)
-- Returns ALL equalities, to be dealt with later
kick_out_rewritable ct (IS { inert_eqs    = eqmap
                           , inert_eq_tvs = inscope
                           , inert_dicts  = dictmap
                           , inert_ips    = ipmap
                           , inert_funeqs = funeqmap
                           , inert_irreds = irreds
                           , inert_frozen = frozen
                           } )
  = ((kicked_out, eqmap), remaining)
  where
    kicked_out = WorkList { wl_eqs    = []
                          , wl_funeqs = bagToList feqs_out
                          , wl_rest   = bagToList (fro_out `andCts` dicts_out 
                                          `andCts` ips_out `andCts` irs_out) }
  
    remaining = IS { inert_eqs = emptyVarEnv
                   , inert_eq_tvs = inscope -- keep the same, safe and cheap
                   , inert_dicts = dicts_in
                   , inert_ips = ips_in
                   , inert_funeqs = feqs_in
                   , inert_irreds = irs_in
                   , inert_frozen = fro_in 
                   }

    fl = cc_flavor ct
    tv = cc_tyvar ct
                               
    (ips_out,   ips_in)     = partitionCCanMap rewritable ipmap

    (feqs_out,  feqs_in)    = partitionCtTypeMap rewritable funeqmap
    (dicts_out, dicts_in)   = partitionCCanMap rewritable dictmap

    (irs_out,   irs_in)   = partitionBag rewritable irreds
    (fro_out,   fro_in)   = partitionBag rewritable frozen

    rewritable ct = (fl `canRewrite` cc_flavor ct)  &&
                    (tv `elemVarSet` tyVarsOfCt ct)
\end{code}

Note [Delicate equality kick-out]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ 

Delicate:
When kicking out rewritable constraints, it would be safe to simply
kick out all rewritable equalities, but instead we only kick out those
that, when rewritten, may result in occur-check errors. We rewrite the
rest on the spot. Example:

          WorkItem =   [S] a ~ b
          Inerts   = { [W] b ~ [a] }
Now at this point the work item cannot be further rewritten by the
inert (due to the weaker inert flavor), so we are examining if we can
instead rewrite the inert from the workitem. But if we rewrite it on
the spot we have to recanonicalize because of the danger of occurs
errors.  On the other hand if the inert flavor was just as powerful or
more powerful than the workitem flavor, the work-item could not have
reached this stage (because it would have already been rewritten by
the inert).

The coclusion is: we kick out the 'dangerous' equalities that may
require recanonicalization (occurs checks) and the rest we rewrite
unconditionally without further checks, on-the-spot with function
rewriteInertEqsFromInertEq.


\begin{code}
data SPSolveResult = SPCantSolve
                   | SPSolved WorkItem 

-- SPCantSolve means that we can't do the unification because e.g. the variable is untouchable
-- SPSolved workItem' gives us a new *given* to go on 

-- @trySpontaneousSolve wi@ solves equalities where one side is a
-- touchable unification variable.
--     	    See Note [Touchables and givens] 
trySpontaneousSolve :: WorkItem -> TcS SPSolveResult
trySpontaneousSolve workItem@(CTyEqCan { cc_id = eqv, cc_flavor = gw
                                       , cc_tyvar = tv1, cc_rhs = xi, cc_depth = d })
  | isGivenOrSolved gw
  = return SPCantSolve
  | Just tv2 <- tcGetTyVar_maybe xi
  = do { tch1 <- isTouchableMetaTyVar tv1
       ; tch2 <- isTouchableMetaTyVar tv2
       ; case (tch1, tch2) of
           (True,  True)  -> trySpontaneousEqTwoWay d eqv gw tv1 tv2
           (True,  False) -> trySpontaneousEqOneWay d eqv gw tv1 xi
           (False, True)  -> trySpontaneousEqOneWay d eqv gw tv2 (mkTyVarTy tv1)
	   _ -> return SPCantSolve }
  | otherwise
  = do { tch1 <- isTouchableMetaTyVar tv1
       ; if tch1 then trySpontaneousEqOneWay d eqv gw tv1 xi
                 else do { traceTcS "Untouchable LHS, can't spontaneously solve workitem:" $
                           ppr workItem 
                         ; return SPCantSolve }
       }

  -- No need for 
  --      trySpontaneousSolve (CFunEqCan ...) = ...
  -- See Note [No touchables as FunEq RHS] in TcSMonad
trySpontaneousSolve _ = return SPCantSolve

----------------
trySpontaneousEqOneWay :: SubGoalDepth 
                       -> EqVar -> CtFlavor -> TcTyVar -> Xi -> TcS SPSolveResult
-- tv is a MetaTyVar, not untouchable
trySpontaneousEqOneWay d eqv gw tv xi	
  | not (isSigTyVar tv) || isTyVarTy xi 
  = do { let kxi = typeKind xi -- NB: 'xi' is fully rewritten according to the inerts 
                               -- so we have its more specific kind in our hands
       ; is_sub_kind <- kxi `isSubKindTcS` tyVarKind tv
       ; if is_sub_kind then
             solveWithIdentity d eqv gw tv xi
         else return SPCantSolve
       }
  | otherwise -- Still can't solve, sig tyvar and non-variable rhs
  = return SPCantSolve

----------------
trySpontaneousEqTwoWay :: SubGoalDepth 
                       -> EqVar -> CtFlavor -> TcTyVar -> TcTyVar -> TcS SPSolveResult
-- Both tyvars are *touchable* MetaTyvars so there is only a chance for kind error here

trySpontaneousEqTwoWay d eqv gw tv1 tv2
  = do { k1_sub_k2 <- k1 `isSubKindTcS` k2
       ; if k1_sub_k2 && nicer_to_update_tv2
         then solveWithIdentity d eqv gw tv2 (mkTyVarTy tv1)
         else do
       { k2_sub_k1 <- k2 `isSubKindTcS` k1
       ; MASSERT( k2_sub_k1 )  -- they were unified in TcCanonical
       ; solveWithIdentity d eqv gw tv1 (mkTyVarTy tv2) } }
  where
    k1 = tyVarKind tv1
    k2 = tyVarKind tv2
    nicer_to_update_tv2 = isSigTyVar tv1 || isSystemName (Var.varName tv2)

\end{code}

Note [Kind errors] 
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider the wanted problem: 
      alpha ~ (# Int, Int #) 
where alpha :: ArgKind and (# Int, Int #) :: (#). We can't spontaneously solve this constraint, 
but we should rather reject the program that give rise to it. If 'trySpontaneousEqTwoWay' 
simply returns @CantSolve@ then that wanted constraint is going to propagate all the way and 
get quantified over in inference mode. That's bad because we do know at this point that the 
constraint is insoluble. Instead, we call 'recKindErrorTcS' here, which will fail later on.

The same applies in canonicalization code in case of kind errors in the givens. 

However, when we canonicalize givens we only check for compatibility (@compatKind@). 
If there were a kind error in the givens, this means some form of inconsistency or dead code.

You may think that when we spontaneously solve wanteds we may have to look through the 
bindings to determine the right kind of the RHS type. E.g one may be worried that xi is 
@alpha@ where alpha :: ? and a previous spontaneous solving has set (alpha := f) with (f :: *).
But we orient our constraints so that spontaneously solved ones can rewrite all other constraint
so this situation can't happen. 

Note [Spontaneous solving and kind compatibility] 
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Note that our canonical constraints insist that *all* equalities (tv ~
xi) or (F xis ~ rhs) require the LHS and the RHS to have *compatible*
the same kinds.  ("compatible" means one is a subKind of the other.)

  - It can't be *equal* kinds, because
     b) wanted constraints don't necessarily have identical kinds
               eg   alpha::? ~ Int
     b) a solved wanted constraint becomes a given

  - SPJ thinks that *given* constraints (tv ~ tau) always have that
    tau has a sub-kind of tv; and when solving wanted constraints
    in trySpontaneousEqTwoWay we re-orient to achieve this.

  - Note that the kind invariant is maintained by rewriting.
    Eg wanted1 rewrites wanted2; if both were compatible kinds before,
       wanted2 will be afterwards.  Similarly givens.

Caveat:
  - Givens from higher-rank, such as: 
          type family T b :: * -> * -> * 
          type instance T Bool = (->) 

          f :: forall a. ((T a ~ (->)) => ...) -> a -> ... 
          flop = f (...) True 
     Whereas we would be able to apply the type instance, we would not be able to 
     use the given (T Bool ~ (->)) in the body of 'flop' 


Note [Avoid double unifications] 
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The spontaneous solver has to return a given which mentions the unified unification
variable *on the left* of the equality. Here is what happens if not: 
  Original wanted:  (a ~ alpha),  (alpha ~ Int) 
We spontaneously solve the first wanted, without changing the order! 
      given : a ~ alpha      [having unified alpha := a] 
Now the second wanted comes along, but he cannot rewrite the given, so we simply continue.
At the end we spontaneously solve that guy, *reunifying*  [alpha := Int] 

We avoid this problem by orienting the resulting given so that the unification
variable is on the left.  [Note that alternatively we could attempt to
enforce this at canonicalization]

See also Note [No touchables as FunEq RHS] in TcSMonad; avoiding
double unifications is the main reason we disallow touchable
unification variables as RHS of type family equations: F xis ~ alpha.

\begin{code}
----------------

solveWithIdentity :: SubGoalDepth 
                  -> EqVar -> CtFlavor -> TcTyVar -> Xi -> TcS SPSolveResult
-- Solve with the identity coercion 
-- Precondition: kind(xi) is a sub-kind of kind(tv)
-- Precondition: CtFlavor is Wanted or Derived
-- See [New Wanted Superclass Work] to see why solveWithIdentity 
--     must work for Derived as well as Wanted
-- Returns: workItem where 
--        workItem = the new Given constraint
solveWithIdentity d eqv wd tv xi 
  = do { traceTcS "Sneaky unification:" $ 
                       vcat [text "Coercion variable:  " <+> ppr eqv <+> ppr wd, 
                             text "Coercion:           " <+> pprEq (mkTyVarTy tv) xi,
                             text "Left  Kind is     : " <+> ppr (typeKind (mkTyVarTy tv)),
                             text "Right Kind is     : " <+> ppr (typeKind xi)
                            ]

       ; setWantedTyBind tv xi
       ; let refl_xi = mkTcReflCo xi

       ; let solved_fl = mkSolvedFlavor wd UnkSkol (EvCoercion refl_xi) 
       ; (_,eqv_given) <- newGivenEqVar solved_fl (mkTyVarTy tv) xi refl_xi

       ; when (isWanted wd) $ do { _ <- setEqBind eqv refl_xi wd; return () }
           -- We don't want to do this for Derived, that's why we use 'when (isWanted wd)'
       ; return $ SPSolved (CTyEqCan { cc_id     = eqv_given
                                     , cc_flavor = solved_fl
                                     , cc_tyvar  = tv, cc_rhs = xi, cc_depth = d }) }
\end{code}


*********************************************************************************
*                                                                               * 
                       The interact-with-inert Stage
*                                                                               *
*********************************************************************************

Note [The Solver Invariant]
~~~~~~~~~~~~~~~~~~~~~~~~~~~
We always add Givens first.  So you might think that the solver has
the invariant

   If the work-item is Given, 
   then the inert item must Given

But this isn't quite true.  Suppose we have, 
    c1: [W] beta ~ [alpha], c2 : [W] blah, c3 :[W] alpha ~ Int
After processing the first two, we get
     c1: [G] beta ~ [alpha], c2 : [W] blah
Now, c3 does not interact with the the given c1, so when we spontaneously
solve c3, we must re-react it with the inert set.  So we can attempt a 
reaction between inert c2 [W] and work-item c3 [G].

It *is* true that [Solver Invariant]
   If the work-item is Given, 
   AND there is a reaction
   then the inert item must Given
or, equivalently,
   If the work-item is Given, 
   and the inert item is Wanted/Derived
   then there is no reaction

\begin{code}
-- Interaction result of  WorkItem <~> AtomicInert

data InteractResult 
    = IRWorkItemConsumed { ir_fire :: String } 
    | IRInertConsumed    { ir_fire :: String } 
    | IRKeepGoing        { ir_fire :: String }

irWorkItemConsumed :: String -> TcS InteractResult
irWorkItemConsumed str = return (IRWorkItemConsumed str) 

irInertConsumed :: String -> TcS InteractResult
irInertConsumed str = return (IRInertConsumed str) 

irKeepGoing :: String -> TcS InteractResult 
irKeepGoing str = return (IRKeepGoing str) 
-- You can't discard neither workitem or inert, but you must keep 
-- going. It's possible that new work is waiting in the TcS worklist. 


interactWithInertsStage :: WorkItem -> TcS StopOrContinue 
-- Precondition: if the workitem is a CTyEqCan then it will not be able to 
-- react with anything at this stage. 
interactWithInertsStage wi 
  = do { ctxt <- getTcSContext
       ; if simplEqsOnly ctxt then 
             return (ContinueWith wi)
         else 
             extractRelevantInerts wi >>= 
               foldlBagM interact_next (ContinueWith wi) }

  where interact_next Stop atomic_inert 
          = updInertSetTcS atomic_inert >> return Stop
        interact_next (ContinueWith wi) atomic_inert 
          = do { ir <- doInteractWithInert atomic_inert wi
               ; let mk_msg rule keep_doc 
                       = text rule <+> keep_doc
      	                 <+> vcat [ ptext (sLit "Inert =") <+> ppr atomic_inert
      	                          , ptext (sLit "Work =")  <+> ppr wi ]
               ; case ir of 
                   IRWorkItemConsumed { ir_fire = rule } 
                       -> do { bumpStepCountTcS
                             ; traceFireTcS (cc_depth wi) 
                                            (mk_msg rule (text "WorkItemConsumed"))
                             ; updInertSetTcS atomic_inert
                             ; return Stop } 
                   IRInertConsumed { ir_fire = rule }
                       -> do { bumpStepCountTcS
                             ; traceFireTcS (cc_depth atomic_inert) 
                                            (mk_msg rule (text "InertItemConsumed"))
                             ; return (ContinueWith wi) }
                   IRKeepGoing {} -- Should we do a bumpStepCountTcS? No for now.
                       -> do { updInertSetTcS atomic_inert
                             ; return (ContinueWith wi) }
               }
   
--------------------------------------------
data WhichComesFromInert = LeftComesFromInert | RightComesFromInert

doInteractWithInert :: Ct -> Ct -> TcS InteractResult
-- Identical class constraints.
doInteractWithInert
  inertItem@(CDictCan { cc_id = d1, cc_flavor = fl1, cc_class = cls1, cc_tyargs = tys1 }) 
   workItem@(CDictCan { cc_id = _d2, cc_flavor = fl2, cc_class = cls2, cc_tyargs = tys2 })

  | cls1 == cls2  
  = do { let pty1 = mkClassPred cls1 tys1
             pty2 = mkClassPred cls2 tys2
             inert_pred_loc     = (pty1, pprFlavorArising fl1)
             work_item_pred_loc = (pty2, pprFlavorArising fl2)

       ; traceTcS "doInteractWithInert" (vcat [ text "inertItem = " <+> ppr inertItem
                                              , text "workItem  = " <+> ppr workItem ])

       ; any_fundeps 
           <- if isGivenOrSolved fl1 && isGivenOrSolved fl2 then return Nothing
              -- NB: We don't create fds for given (and even solved), have not seen a useful
              -- situation for these and even if we did we'd have to be very careful to only
              -- create Derived's and not Wanteds. 

              else let fd_eqns = improveFromAnother inert_pred_loc work_item_pred_loc
                       wloc    = get_workitem_wloc fl2 
                   in rewriteWithFunDeps fd_eqns tys2 wloc
                      -- See Note [Efficient Orientation], [When improvement happens]

       ; case any_fundeps of
           -- No Functional Dependencies 
           Nothing             
               | eqTypes tys1 tys2 -> solveOneFromTheOther "Cls/Cls" (EvId d1,fl1) workItem
               | otherwise         -> irKeepGoing "NOP"

           -- Actual Functional Dependencies
           Just (_rewritten_tys2,_cos2,fd_work)
              -- Standard thing: create derived fds and keep on going. Importantly we don't
               -- throw workitem back in the worklist because this can cause loops. See #5236.
               -> do { emitFDWorkAsDerived fd_work (cc_depth workItem)
                     ; irKeepGoing "Cls/Cls (new fundeps)" } -- Just keep going without droping the inert 
       }
  where get_workitem_wloc (Wanted wl)  = wl 
        get_workitem_wloc (Derived wl) = wl 
        get_workitem_wloc (Given {})   = panic "Unexpected given!"


-- Two pieces of irreducible evidence: if their types are *exactly identical* we can
-- rewrite them. We can never improve using this: if we want ty1 :: Constraint and have
-- ty2 :: Constraint it clearly does not mean that (ty1 ~ ty2)
doInteractWithInert (CIrredEvCan { cc_id = id1, cc_flavor = ifl, cc_ty = ty1 })
           workItem@(CIrredEvCan { cc_ty = ty2 })
  | ty1 `eqType` ty2
  = solveOneFromTheOther "Irred/Irred" (EvId id1,ifl) workItem

-- Two implicit parameter constraints.  If the names are the same,
-- but their types are not, we generate a wanted type equality 
-- that equates the type (this is "improvement").  
-- However, we don't actually need the coercion evidence,
-- so we just generate a fresh coercion variable that isn't used anywhere.
doInteractWithInert (CIPCan { cc_id = id1, cc_flavor = ifl, cc_ip_nm = nm1, cc_ip_ty = ty1 }) 
           workItem@(CIPCan { cc_flavor = wfl, cc_ip_nm = nm2, cc_ip_ty = ty2 })
  | nm1 == nm2 && isGivenOrSolved wfl && isGivenOrSolved ifl
  = 	-- See Note [Overriding implicit parameters]
        -- Dump the inert item, override totally with the new one
	-- Do not require type equality
	-- For example, given let ?x::Int = 3 in let ?x::Bool = True in ...
	--              we must *override* the outer one with the inner one
    irInertConsumed "IP/IP (override inert)"

  | nm1 == nm2 && ty1 `eqType` ty2 
  = solveOneFromTheOther "IP/IP" (EvId id1,ifl) workItem 

  | nm1 == nm2
  =  	-- See Note [When improvement happens]
    do { let flav = Wanted (combineCtLoc ifl wfl)
       ; eqv <- newEqVar flav ty2 ty1 -- See Note [Efficient Orientation]
       ; when (isNewEvVar eqv) $
              (let ct = CNonCanonical { cc_id     = evc_the_evvar eqv 
                                      , cc_flavor = flav
                                      , cc_depth  = cc_depth workItem }
              in updWorkListTcS (extendWorkListEq ct))

       ; case wfl of
           Given   {} -> pprPanic "Unexpected given IP" (ppr workItem)
           Derived {} -> pprPanic "Unexpected derived IP" (ppr workItem)
           Wanted  {} ->
               do { _ <- setEvBind (cc_id workItem) 
                            (mkEvCast id1 (mkTcSymCo (mkTcTyConAppCo (ipTyCon nm1) [mkTcCoVarCo (evc_the_evvar eqv)]))) wfl
                  ; irWorkItemConsumed "IP/IP (solved by rewriting)" } }

doInteractWithInert (CFunEqCan { cc_id = eqv1, cc_flavor = fl1, cc_fun = tc1
                               , cc_tyargs = args1, cc_rhs = xi1, cc_depth = d1 }) 
                    (CFunEqCan { cc_id = eqv2, cc_flavor = fl2, cc_fun = tc2
                               , cc_tyargs = args2, cc_rhs = xi2, cc_depth = d2 })
  | lhss_match  
  , Just (GivenSolved {}) <- isGiven_maybe fl1 -- Inert is solved and we can simply ignore it
                                          -- when workitem is given/solved
  , isGivenOrSolved fl2
  = irInertConsumed "FunEq/FunEq"
  | lhss_match 
  , Just (GivenSolved {}) <- isGiven_maybe fl2 -- Workitem is solved and we can ignore it when
                                               -- the inert is given/solved
  , isGivenOrSolved fl1                 
  = irWorkItemConsumed "FunEq/FunEq" 
  | fl1 `canSolve` fl2 && lhss_match
  = do { rewriteEqLHS LeftComesFromInert  (eqv1,xi1) (eqv2,d2,fl2,xi2) 
       ; irWorkItemConsumed "FunEq/FunEq" }

  | fl2 `canSolve` fl1 && lhss_match
  = do { rewriteEqLHS RightComesFromInert (eqv2,xi2) (eqv1,d1,fl1,xi1) 
       ; irInertConsumed "FunEq/FunEq"}
  where
    lhss_match = tc1 == tc2 && eqTypes args1 args2 


doInteractWithInert _ _ = irKeepGoing "NOP"


rewriteEqLHS :: WhichComesFromInert -> (EqVar,Xi) -> (EqVar,SubGoalDepth,CtFlavor,Xi) -> TcS ()
-- Used to ineract two equalities of the following form: 
-- First Equality:   co1: (XXX ~ xi1)  
-- Second Equality:  cv2: (XXX ~ xi2) 
-- Where the cv1 `canRewrite` cv2 equality 
-- We have an option of creating new work (xi1 ~ xi2) OR (xi2 ~ xi1), 
--    See Note [Efficient Orientation] for that 
rewriteEqLHS LeftComesFromInert (eqv1,xi1) (eqv2,d,gw,xi2) 
  = do { delCachedEvVar eqv2 gw -- Similarly to canonicalization!
       ; evc <- newEqVar gw xi2 xi1
       ; let eqv2' = evc_the_evvar evc
       ; gw' <- case gw of 
           Wanted {} 
               -> setEqBind eqv2 
                    (mkTcCoVarCo eqv1 `mkTcTransCo` mkTcSymCo (mkTcCoVarCo eqv2')) gw
           Given {}
               -> setEqBind eqv2'
                    (mkTcSymCo (mkTcCoVarCo eqv2) `mkTcTransCo` mkTcCoVarCo eqv1) gw
           Derived {} 
               -> return gw
       ; when (isNewEvVar evc) $ 
              updWorkListTcS (extendWorkListEq (CNonCanonical { cc_id     = eqv2'
                                                              , cc_flavor = gw'
                                                              , cc_depth  = d } ) ) }

rewriteEqLHS RightComesFromInert (eqv1,xi1) (eqv2,d,gw,xi2) 
  = do { delCachedEvVar eqv2 gw -- Similarly to canonicalization!
       ; evc <- newEqVar gw xi1 xi2
       ; let eqv2' = evc_the_evvar evc
       ; gw' <- case gw of
           Wanted {} 
               -> setEqBind eqv2
                    (mkTcCoVarCo eqv1 `mkTcTransCo` mkTcCoVarCo eqv2') gw
           Given {}  
               -> setEqBind eqv2'
                    (mkTcSymCo (mkTcCoVarCo eqv1) `mkTcTransCo` mkTcCoVarCo eqv2) gw
           Derived {} 
               -> return gw

       ; when (isNewEvVar evc) $
              updWorkListTcS (extendWorkListEq (CNonCanonical { cc_id = eqv2'
                                                              , cc_flavor = gw'
                                                              , cc_depth  = d } ) ) }

solveOneFromTheOther :: String             -- Info 
                     -> (EvTerm, CtFlavor) -- Inert 
                     -> Ct        -- WorkItem 
                     -> TcS InteractResult
-- Preconditions: 
-- 1) inert and work item represent evidence for the /same/ predicate
-- 2) ip/class/irred evidence (no coercions) only
solveOneFromTheOther info (ev_term,ifl) workItem
  | isDerived wfl
  = irWorkItemConsumed ("Solved[DW] " ++ info)

  | isDerived ifl -- The inert item is Derived, we can just throw it away, 
    	      	  -- The workItem is inert wrt earlier inert-set items, 
		  -- so it's safe to continue on from this point
  = irInertConsumed ("Solved[DI] " ++ info)
  
  | Just (GivenSolved {}) <- isGiven_maybe ifl, isGivenOrSolved wfl
    -- Same if the inert is a GivenSolved -- just get rid of it
  = irInertConsumed ("Solved[SI] " ++ info)

  | otherwise
  = ASSERT( ifl `canSolve` wfl )
      -- Because of Note [The Solver Invariant], plus Derived dealt with
    do { when (isWanted wfl) $ do { _ <- setEvBind wid ev_term wfl; return () }
           -- Overwrite the binding, if one exists
	   -- If both are Given, we already have evidence; no need to duplicate
       ; irWorkItemConsumed ("Solved " ++ info) }
  where 
     wfl = cc_flavor workItem
     wid = cc_id workItem

\end{code}

Note [Superclasses and recursive dictionaries]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    Overlaps with Note [SUPERCLASS-LOOP 1]
                  Note [SUPERCLASS-LOOP 2]
                  Note [Recursive instances and superclases]
    ToDo: check overlap and delete redundant stuff

Right before adding a given into the inert set, we must
produce some more work, that will bring the superclasses 
of the given into scope. The superclass constraints go into 
our worklist. 

When we simplify a wanted constraint, if we first see a matching
instance, we may produce new wanted work. To (1) avoid doing this work 
twice in the future and (2) to handle recursive dictionaries we may ``cache'' 
this item as given into our inert set WITHOUT adding its superclass constraints, 
otherwise we'd be in danger of creating a loop [In fact this was the exact reason
for doing the isGoodRecEv check in an older version of the type checker]. 

But now we have added partially solved constraints to the worklist which may 
interact with other wanteds. Consider the example: 

Example 1: 

    class Eq b => Foo a b        --- 0-th selector
    instance Eq a => Foo [a] a   --- fooDFun

and wanted (Foo [t] t). We are first going to see that the instance matches 
and create an inert set that includes the solved (Foo [t] t) but not its superclasses:
       d1 :_g Foo [t] t                 d1 := EvDFunApp fooDFun d3 
Our work list is going to contain a new *wanted* goal
       d3 :_w Eq t 

Ok, so how do we get recursive dictionaries, at all: 

Example 2:

    data D r = ZeroD | SuccD (r (D r));
    
    instance (Eq (r (D r))) => Eq (D r) where
        ZeroD     == ZeroD     = True
        (SuccD a) == (SuccD b) = a == b
        _         == _         = False;
    
    equalDC :: D [] -> D [] -> Bool;
    equalDC = (==);

We need to prove (Eq (D [])). Here's how we go:

	d1 :_w Eq (D [])

by instance decl, holds if
	d2 :_w Eq [D []]
	where 	d1 = dfEqD d2

*BUT* we have an inert set which gives us (no superclasses): 
        d1 :_g Eq (D []) 
By the instance declaration of Eq we can show the 'd2' goal if 
	d3 :_w Eq (D [])
	where	d2 = dfEqList d3
		d1 = dfEqD d2
Now, however this wanted can interact with our inert d1 to set: 
        d3 := d1 
and solve the goal. Why was this interaction OK? Because, if we chase the 
evidence of d1 ~~> dfEqD d2 ~~-> dfEqList d3, so by setting d3 := d1 we 
are really setting
        d3 := dfEqD2 (dfEqList d3) 
which is FINE because the use of d3 is protected by the instance function 
applications. 

So, our strategy is to try to put solved wanted dictionaries into the
inert set along with their superclasses (when this is meaningful,
i.e. when new wanted goals are generated) but solve a wanted dictionary
from a given only in the case where the evidence variable of the
wanted is mentioned in the evidence of the given (recursively through
the evidence binds) in a protected way: more instance function applications 
than superclass selectors.

Here are some more examples from GHC's previous type checker


Example 3: 
This code arises in the context of "Scrap Your Boilerplate with Class"

    class Sat a
    class Data ctx a
    instance  Sat (ctx Char)             => Data ctx Char       -- dfunData1
    instance (Sat (ctx [a]), Data ctx a) => Data ctx [a]        -- dfunData2

    class Data Maybe a => Foo a    

    instance Foo t => Sat (Maybe t)                             -- dfunSat

    instance Data Maybe a => Foo a                              -- dfunFoo1
    instance Foo a        => Foo [a]                            -- dfunFoo2
    instance                 Foo [Char]                         -- dfunFoo3

Consider generating the superclasses of the instance declaration
	 instance Foo a => Foo [a]

So our problem is this
    d0 :_g Foo t
    d1 :_w Data Maybe [t] 

We may add the given in the inert set, along with its superclasses
[assuming we don't fail because there is a matching instance, see 
 tryTopReact, given case ]
  Inert:
    d0 :_g Foo t 
  WorkList 
    d01 :_g Data Maybe t  -- d2 := EvDictSuperClass d0 0 
    d1 :_w Data Maybe [t] 
Then d2 can readily enter the inert, and we also do solving of the wanted
  Inert: 
    d0 :_g Foo t 
    d1 :_s Data Maybe [t]           d1 := dfunData2 d2 d3 
  WorkList
    d2 :_w Sat (Maybe [t])          
    d3 :_w Data Maybe t
    d01 :_g Data Maybe t 
Now, we may simplify d2 more: 
  Inert:
      d0 :_g Foo t 
      d1 :_s Data Maybe [t]           d1 := dfunData2 d2 d3 
      d1 :_g Data Maybe [t] 
      d2 :_g Sat (Maybe [t])          d2 := dfunSat d4 
  WorkList: 
      d3 :_w Data Maybe t 
      d4 :_w Foo [t] 
      d01 :_g Data Maybe t 

Now, we can just solve d3.
  Inert
      d0 :_g Foo t 
      d1 :_s Data Maybe [t]           d1 := dfunData2 d2 d3 
      d2 :_g Sat (Maybe [t])          d2 := dfunSat d4 
  WorkList
      d4 :_w Foo [t] 
      d01 :_g Data Maybe t 
And now we can simplify d4 again, but since it has superclasses we *add* them to the worklist:
  Inert
      d0 :_g Foo t 
      d1 :_s Data Maybe [t]           d1 := dfunData2 d2 d3 
      d2 :_g Sat (Maybe [t])          d2 := dfunSat d4 
      d4 :_g Foo [t]                  d4 := dfunFoo2 d5 
  WorkList:
      d5 :_w Foo t 
      d6 :_g Data Maybe [t]           d6 := EvDictSuperClass d4 0
      d01 :_g Data Maybe t 
Now, d5 can be solved! (and its superclass enter scope) 
  Inert
      d0 :_g Foo t 
      d1 :_s Data Maybe [t]           d1 := dfunData2 d2 d3 
      d2 :_g Sat (Maybe [t])          d2 := dfunSat d4 
      d4 :_g Foo [t]                  d4 := dfunFoo2 d5 
      d5 :_g Foo t                    d5 := dfunFoo1 d7
  WorkList:
      d7 :_w Data Maybe t
      d6 :_g Data Maybe [t]
      d8 :_g Data Maybe t            d8 := EvDictSuperClass d5 0
      d01 :_g Data Maybe t 

Now, two problems: 
   [1] Suppose we pick d8 and we react him with d01. Which of the two givens should 
       we keep? Well, we *MUST NOT* drop d01 because d8 contains recursive evidence 
       that must not be used (look at case interactInert where both inert and workitem
       are givens). So we have several options: 
       - Drop the workitem always (this will drop d8)
              This feels very unsafe -- what if the work item was the "good" one
              that should be used later to solve another wanted?
       - Don't drop anyone: the inert set may contain multiple givens! 
              [This is currently implemented] 

The "don't drop anyone" seems the most safe thing to do, so now we come to problem 2: 
  [2] We have added both d6 and d01 in the inert set, and we are interacting our wanted
      d7. Now the [isRecDictEv] function in the ineration solver 
      [case inert-given workitem-wanted] will prevent us from interacting d7 := d8 
      precisely because chasing the evidence of d8 leads us to an unguarded use of d7. 

      So, no interaction happens there. Then we meet d01 and there is no recursion 
      problem there [isRectDictEv] gives us the OK to interact and we do solve d7 := d01! 
             
Note [SUPERCLASS-LOOP 1]
~~~~~~~~~~~~~~~~~~~~~~~~
We have to be very, very careful when generating superclasses, lest we
accidentally build a loop. Here's an example:

  class S a

  class S a => C a where { opc :: a -> a }
  class S b => D b where { opd :: b -> b }
  
  instance C Int where
     opc = opd
  
  instance D Int where
     opd = opc

From (instance C Int) we get the constraint set {ds1:S Int, dd:D Int}
Simplifying, we may well get:
	$dfCInt = :C ds1 (opd dd)
	dd  = $dfDInt
	ds1 = $p1 dd
Notice that we spot that we can extract ds1 from dd.  

Alas!  Alack! We can do the same for (instance D Int):

	$dfDInt = :D ds2 (opc dc)
	dc  = $dfCInt
	ds2 = $p1 dc

And now we've defined the superclass in terms of itself.
Two more nasty cases are in
	tcrun021
	tcrun033

Solution: 
  - Satisfy the superclass context *all by itself* 
    (tcSimplifySuperClasses)
  - And do so completely; i.e. no left-over constraints
    to mix with the constraints arising from method declarations


Note [SUPERCLASS-LOOP 2]
~~~~~~~~~~~~~~~~~~~~~~~~
We need to be careful when adding "the constaint we are trying to prove".
Suppose we are *given* d1:Ord a, and want to deduce (d2:C [a]) where

	class Ord a => C a where
	instance Ord [a] => C [a] where ...

Then we'll use the instance decl to deduce C [a] from Ord [a], and then add the
superclasses of C [a] to avails.  But we must not overwrite the binding
for Ord [a] (which is obtained from Ord a) with a superclass selection or we'll just
build a loop! 

Here's another variant, immortalised in tcrun020
	class Monad m => C1 m
	class C1 m => C2 m x
	instance C2 Maybe Bool
For the instance decl we need to build (C1 Maybe), and it's no good if
we run around and add (C2 Maybe Bool) and its superclasses to the avails 
before we search for C1 Maybe.

Here's another example 
 	class Eq b => Foo a b
	instance Eq a => Foo [a] a
If we are reducing
	(Foo [t] t)

we'll first deduce that it holds (via the instance decl).  We must not
then overwrite the Eq t constraint with a superclass selection!

At first I had a gross hack, whereby I simply did not add superclass constraints
in addWanted, though I did for addGiven and addIrred.  This was sub-optimal,
becuase it lost legitimate superclass sharing, and it still didn't do the job:
I found a very obscure program (now tcrun021) in which improvement meant the
simplifier got two bites a the cherry... so something seemed to be an Stop
first time, but reducible next time.

Now we implement the Right Solution, which is to check for loops directly 
when adding superclasses.  It's a bit like the occurs check in unification.

Note [Recursive instances and superclases]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider this code, which arises in the context of "Scrap Your 
Boilerplate with Class".  

    class Sat a
    class Data ctx a
    instance  Sat (ctx Char)             => Data ctx Char
    instance (Sat (ctx [a]), Data ctx a) => Data ctx [a]

    class Data Maybe a => Foo a

    instance Foo t => Sat (Maybe t)

    instance Data Maybe a => Foo a
    instance Foo a        => Foo [a]
    instance                 Foo [Char]

In the instance for Foo [a], when generating evidence for the superclasses
(ie in tcSimplifySuperClasses) we need a superclass (Data Maybe [a]).
Using the instance for Data, we therefore need
        (Sat (Maybe [a], Data Maybe a)
But we are given (Foo a), and hence its superclass (Data Maybe a).
So that leaves (Sat (Maybe [a])).  Using the instance for Sat means
we need (Foo [a]).  And that is the very dictionary we are bulding
an instance for!  So we must put that in the "givens".  So in this
case we have
	Given:  Foo a, Foo [a]
	Wanted: Data Maybe [a]

BUT we must *not not not* put the *superclasses* of (Foo [a]) in
the givens, which is what 'addGiven' would normally do. Why? Because
(Data Maybe [a]) is the superclass, so we'd "satisfy" the wanted 
by selecting a superclass from Foo [a], which simply makes a loop.

On the other hand we *must* put the superclasses of (Foo a) in
the givens, as you can see from the derivation described above.

Conclusion: in the very special case of tcSimplifySuperClasses
we have one 'given' (namely the "this" dictionary) whose superclasses
must not be added to 'givens' by addGiven.  

There is a complication though.  Suppose there are equalities
      instance (Eq a, a~b) => Num (a,b)
Then we normalise the 'givens' wrt the equalities, so the original
given "this" dictionary is cast to one of a different type.  So it's a
bit trickier than before to identify the "special" dictionary whose
superclasses must not be added. See test
   indexed-types/should_run/EqInInstance

We need a persistent property of the dictionary to record this
special-ness.  Current I'm using the InstLocOrigin (a bit of a hack,
but cool), which is maintained by dictionary normalisation.
Specifically, the InstLocOrigin is
	     NoScOrigin
then the no-superclass thing kicks in.  WATCH OUT if you fiddle
with InstLocOrigin!

Note [MATCHING-SYNONYMS]
~~~~~~~~~~~~~~~~~~~~~~~~
When trying to match a dictionary (D tau) to a top-level instance, or a 
type family equation (F taus_1 ~ tau_2) to a top-level family instance, 
we do *not* need to expand type synonyms because the matcher will do that for us.


Note [RHS-FAMILY-SYNONYMS] 
~~~~~~~~~~~~~~~~~~~~~~~~~~
The RHS of a family instance is represented as yet another constructor which is 
like a type synonym for the real RHS the programmer declared. Eg: 
    type instance F (a,a) = [a] 
Becomes: 
    :R32 a = [a]      -- internal type synonym introduced
    F (a,a) ~ :R32 a  -- instance 

When we react a family instance with a type family equation in the work list 
we keep the synonym-using RHS without expansion. 


*********************************************************************************
*                                                                               * 
                       The top-reaction Stage
*                                                                               *
*********************************************************************************

\begin{code}

topReactionsStage :: SimplifierStage 
topReactionsStage workItem 
 = tryTopReact workItem 
   

tryTopReact :: WorkItem -> TcS StopOrContinue
tryTopReact wi 
 = do { inerts <- getTcSInerts
      ; ctxt   <- getTcSContext
      ; if simplEqsOnly ctxt then return (ContinueWith wi) -- or Stop?
        else 
            do { tir <- doTopReact inerts wi
               ; case tir of 
                   NoTopInt 
                       -> return (ContinueWith wi)
                   SomeTopInt rule what_next 
                       -> do { bumpStepCountTcS 
                             ; traceFireTcS (cc_depth wi) $
                               ptext (sLit "Top react:") <+> text rule
                             ; return what_next }
               } }

data TopInteractResult 
 = NoTopInt
 | SomeTopInt { tir_rule :: String, tir_new_item :: StopOrContinue }


doTopReact :: InertSet -> WorkItem -> TcS TopInteractResult

-- The work item does not react with the inert set, so try interaction
-- with top-level instances 
-- NB: The place to add superclasses in *not*
-- in doTopReact stage. Instead superclasses are added in the worklist
-- as part of the canonicalisation process. See Note [Adding superclasses].


-- Given dictionary
-- See Note [Given constraint that matches an instance declaration]
doTopReact _inerts (CDictCan { cc_flavor = Given {} })
  = return NoTopInt -- NB: Superclasses already added since it's canonical

-- Derived dictionary: just look for functional dependencies
doTopReact _inerts workItem@(CDictCan { cc_flavor = Derived loc
                                      , cc_class = cls, cc_tyargs = xis })
  = do { instEnvs <- getInstEnvs
       ; let fd_eqns = improveFromInstEnv instEnvs
                           (mkClassPred cls xis, pprArisingAt loc)
       ; m <- rewriteWithFunDeps fd_eqns xis loc
       ; case m of
           Nothing -> return NoTopInt
           Just (xis',_,fd_work) ->
               let workItem' = workItem { cc_tyargs = xis' }
                   -- Deriveds are not supposed to have identity (cc_id is unused!)
               in do { emitFDWorkAsDerived fd_work (cc_depth workItem)
                     ; return $ 
                       SomeTopInt { tir_rule  = "Derived Cls fundeps" 
                                  , tir_new_item = ContinueWith workItem' } }
       }

-- Wanted dictionary
doTopReact inerts workItem@(CDictCan { cc_flavor = fl@(Wanted loc)
                                     , cc_class = cls, cc_tyargs = xis })
  -- See Note [MATCHING-SYNONYMS]
  = do { traceTcS "doTopReact" (ppr workItem)
       ; instEnvs <- getInstEnvs
       ; let fd_eqns = improveFromInstEnv instEnvs 
                            (mkClassPred cls xis, pprArisingAt loc)

       ; any_fundeps <- rewriteWithFunDeps fd_eqns xis loc
       ; case any_fundeps of
           -- No Functional Dependencies
           Nothing ->
               do { lkup_inst_res  <- matchClassInst inerts cls xis loc
                  ; case lkup_inst_res of
                      GenInst wtvs ev_term
                          -> doSolveFromInstance wtvs ev_term workItem
                      NoInstance
                          -> return NoTopInt
                  }
           -- Actual Functional Dependencies
           Just (_xis',_cos,fd_work) ->
               do { emitFDWorkAsDerived fd_work (cc_depth workItem)
                  ; return SomeTopInt { tir_rule = "Dict/Top (fundeps)"
                                      , tir_new_item = ContinueWith workItem } } }

   where doSolveFromInstance :: [WantedEvVar] 
                             -> EvTerm 
                             -> Ct 
                             -> TcS TopInteractResult
         -- Precondition: evidence term matches the predicate of cc_id of workItem
         doSolveFromInstance wtvs ev_term workItem
            | null wtvs
            = do { traceTcS "doTopReact/found nullary instance for" (ppr (cc_id workItem))
                 ; _ <- setEvBind (cc_id workItem) ev_term fl
                 ; return $ 
                   SomeTopInt { tir_rule = "Dict/Top (solved, no new work)" 
                              , tir_new_item = Stop } } -- Don't put him in the inerts
            | otherwise 
            = do { traceTcS "doTopReact/found non-nullary instance for" $ 
                   ppr (cc_id workItem)
                 ; _ <- setEvBind (cc_id workItem) ev_term fl
                        -- Solved and new wanted work produced, you may cache the 
                        -- (tentatively solved) dictionary as Solved given.
--                 ; let _solved = workItem { cc_flavor = solved_fl }
--                       solved_fl = mkSolvedFlavor fl UnkSkol
                 ; let ct_from_wev (EvVarX v fl)
                           = CNonCanonical { cc_id = v, cc_flavor = Wanted fl
                                           , cc_depth  = cc_depth workItem + 1 }
                       wtvs_cts = map ct_from_wev wtvs
                 ; updWorkListTcS (appendWorkListCt wtvs_cts)
                 ; return $
                   SomeTopInt { tir_rule     = "Dict/Top (solved, more work)"
                              , tir_new_item = Stop }
                 }
--                              , tir_new_item = ContinueWith solved } } -- Cache in inerts the Solved item

-- Type functions
doTopReact _inerts (CFunEqCan { cc_flavor = fl })
  | Just (GivenSolved {}) <- isGiven_maybe fl
  = return NoTopInt -- If Solved, no more interactions should happen

-- Otherwise, it's a Given, Derived, or Wanted
doTopReact _inerts workItem@(CFunEqCan { cc_id = eqv, cc_flavor = fl
                                       , cc_fun = tc, cc_tyargs = args, cc_rhs = xi })
  = ASSERT (isSynFamilyTyCon tc)   -- No associated data families have reached that far 
    do { match_res <- matchFam tc args   -- See Note [MATCHING-SYNONYMS]
       ; case match_res of 
           Nothing -> return NoTopInt 
           Just (rep_tc, rep_tys)
             -> do { let Just coe_tc = tyConFamilyCoercion_maybe rep_tc
                         Just rhs_ty = tcView (mkTyConApp rep_tc rep_tys)
			    -- Eagerly expand away the type synonym on the
			    -- RHS of a type function, so that it never
			    -- appears in an error message
                            -- See Note [Type synonym families] in TyCon
                         coe = mkTcAxInstCo coe_tc rep_tys 
                   ; case fl of
                       Wanted {} -> do { evc <- newEqVar fl rhs_ty xi -- Wanted version
                                       ; let eqv' = evc_the_evvar evc
                                       ; let coercion = coe `mkTcTransCo` mkTcCoVarCo eqv'
                                       ; _ <- setEqBind eqv coercion fl
                                       ; when (isNewEvVar evc) $ 
                                            (let ct = CNonCanonical { cc_id = eqv'
                                                                    , cc_flavor = fl 
                                                                    , cc_depth = cc_depth workItem + 1} 
                                             in updWorkListTcS (extendWorkListEq ct))

                                       ; let _solved   = workItem { cc_flavor = solved_fl }
                                             solved_fl = mkSolvedFlavor fl UnkSkol (EvCoercion coercion)

                                       ; updateFlatCache eqv solved_fl tc args xi WhenSolved

                                       ; return $ 
                                         SomeTopInt { tir_rule = "Fun/Top (solved, more work)"
                                                    , tir_new_item = Stop } }
                                                  --  , tir_new_item = ContinueWith solved } }
                                                     -- Cache in inerts the Solved item

                       Given {} -> do { (fl',eqv') <- newGivenEqVar fl xi rhs_ty $ 
                                                         mkTcSymCo (mkTcCoVarCo eqv) `mkTcTransCo` coe
                                      ; let ct = CNonCanonical { cc_id = eqv'
                                                               , cc_flavor = fl'
                                                               , cc_depth = cc_depth workItem + 1}  
                                      ; updWorkListTcS (extendWorkListEq ct) 

                                      ; return $ 
                                        SomeTopInt { tir_rule = "Fun/Top (given)"
                                                   , tir_new_item = ContinueWith workItem } }
                       Derived {} -> do { evc <- newEvVar fl (mkEqPred (xi, rhs_ty))
                                        ; let eqv' = evc_the_evvar evc
                                        ; when (isNewEvVar evc) $ 
                                            (let ct = CNonCanonical { cc_id  = eqv'
                                                                 , cc_flavor = fl
                                                                 , cc_depth  = cc_depth workItem + 1 } 
                                             in updWorkListTcS (extendWorkListEq ct)) 
                                        ; return $ 
                                          SomeTopInt { tir_rule = "Fun/Top (derived)"
                                                     , tir_new_item = Stop } }
                   }
       }


-- Any other work item does not react with any top-level equations
doTopReact _inerts _workItem = return NoTopInt 
\end{code}


Note [FunDep and implicit parameter reactions] 
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Currently, our story of interacting two dictionaries (or a dictionary
and top-level instances) for functional dependencies, and implicit
paramters, is that we simply produce new wanted equalities.  So for example

        class D a b | a -> b where ... 
    Inert: 
        d1 :g D Int Bool
    WorkItem: 
        d2 :w D Int alpha

    We generate the extra work item
        cv :w alpha ~ Bool
    where 'cv' is currently unused.  However, this new item reacts with d2,
    discharging it in favour of a new constraint d2' thus:
        d2' :w D Int Bool
	d2 := d2' |> D Int cv
    Now d2' can be discharged from d1

We could be more aggressive and try to *immediately* solve the dictionary 
using those extra equalities. With the same inert set and work item we
might dischard d2 directly:

        cv :w alpha ~ Bool
        d2 := d1 |> D Int cv

But in general it's a bit painful to figure out the necessary coercion,
so we just take the first approach. Here is a better example. Consider:
    class C a b c | a -> b 
And: 
     [Given]  d1 : C T Int Char 
     [Wanted] d2 : C T beta Int 
In this case, it's *not even possible* to solve the wanted immediately. 
So we should simply output the functional dependency and add this guy
[but NOT its superclasses] back in the worklist. Even worse: 
     [Given] d1 : C T Int beta 
     [Wanted] d2: C T beta Int 
Then it is solvable, but its very hard to detect this on the spot. 

It's exactly the same with implicit parameters, except that the
"aggressive" approach would be much easier to implement.

Note [When improvement happens]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
We fire an improvement rule when

  * Two constraints match (modulo the fundep)
      e.g. C t1 t2, C t1 t3    where C a b | a->b
    The two match because the first arg is identical

  * At least one is not Given.  If they are both given, we don't fire
    the reaction because we have no way of constructing evidence for a
    new equality nor does it seem right to create a new wanted goal
    (because the goal will most likely contain untouchables, which
    can't be solved anyway)!
   
Note that we *do* fire the improvement if one is Given and one is Derived.
The latter can be a superclass of a wanted goal. Example (tcfail138)
    class L a b | a -> b
    class (G a, L a b) => C a b

    instance C a b' => G (Maybe a)
    instance C a b  => C (Maybe a) a
    instance L (Maybe a) a

When solving the superclasses of the (C (Maybe a) a) instance, we get
  Given:  C a b  ... and hance by superclasses, (G a, L a b)
  Wanted: G (Maybe a)
Use the instance decl to get
  Wanted: C a b'
The (C a b') is inert, so we generate its Derived superclasses (L a b'),
and now we need improvement between that derived superclass an the Given (L a b)

Note [Overriding implicit parameters]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider
   f :: (?x::a) -> Bool -> a
  
   g v = let ?x::Int = 3 
         in (f v, let ?x::Bool = True in f v)

This should probably be well typed, with
   g :: Bool -> (Int, Bool)

So the inner binding for ?x::Bool *overrides* the outer one.
Hence a work-item Given overrides an inert-item Given.

Note [Given constraint that matches an instance declaration]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
What should we do when we discover that one (or more) top-level 
instances match a given (or solved) class constraint? We have 
two possibilities:

  1. Reject the program. The reason is that there may not be a unique
     best strategy for the solver. Example, from the OutsideIn(X) paper:
       instance P x => Q [x] 
       instance (x ~ y) => R [x] y 
     
       wob :: forall a b. (Q [b], R b a) => a -> Int 

       g :: forall a. Q [a] => [a] -> Int 
       g x = wob x 

       will generate the impliation constraint: 
            Q [a] => (Q [beta], R beta [a]) 
       If we react (Q [beta]) with its top-level axiom, we end up with a 
       (P beta), which we have no way of discharging. On the other hand, 
       if we react R beta [a] with the top-level we get  (beta ~ a), which 
       is solvable and can help us rewrite (Q [beta]) to (Q [a]) which is 
       now solvable by the given Q [a]. 
 
     However, this option is restrictive, for instance [Example 3] from 
     Note [Recursive instances and superclases] will fail to work. 

  2. Ignore the problem, hoping that the situations where there exist indeed
     such multiple strategies are rare: Indeed the cause of the previous 
     problem is that (R [x] y) yields the new work (x ~ y) which can be 
     *spontaneously* solved, not using the givens. 

We are choosing option 2 below but we might consider having a flag as well.


Note [New Wanted Superclass Work] 
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Even in the case of wanted constraints, we may add some superclasses 
as new given work. The reason is: 

        To allow FD-like improvement for type families. Assume that 
        we have a class 
             class C a b | a -> b 
        and we have to solve the implication constraint: 
             C a b => C a beta 
        Then, FD improvement can help us to produce a new wanted (beta ~ b) 

        We want to have the same effect with the type family encoding of 
        functional dependencies. Namely, consider: 
             class (F a ~ b) => C a b 
        Now suppose that we have: 
               given: C a b 
               wanted: C a beta 
        By interacting the given we will get given (F a ~ b) which is not 
        enough by itself to make us discharge (C a beta). However, we 
        may create a new derived equality from the super-class of the
        wanted constraint (C a beta), namely derived (F a ~ beta). 
        Now we may interact this with given (F a ~ b) to get: 
                  derived :  beta ~ b 
        But 'beta' is a touchable unification variable, and hence OK to 
        unify it with 'b', replacing the derived evidence with the identity. 

        This requires trySpontaneousSolve to solve *derived*
        equalities that have a touchable in their RHS, *in addition*
        to solving wanted equalities.

We also need to somehow use the superclasses to quantify over a minimal, 
constraint see note [Minimize by Superclasses] in TcSimplify.


Finally, here is another example where this is useful. 

Example 1:
----------
   class (F a ~ b) => C a b 
And we are given the wanteds:
      w1 : C a b 
      w2 : C a c 
      w3 : b ~ c 
We surely do *not* want to quantify over (b ~ c), since if someone provides
dictionaries for (C a b) and (C a c), these dictionaries can provide a proof 
of (b ~ c), hence no extra evidence is necessary. Here is what will happen: 

     Step 1: We will get new *given* superclass work, 
             provisionally to our solving of w1 and w2
             
               g1: F a ~ b, g2 : F a ~ c, 
               w1 : C a b, w2 : C a c, w3 : b ~ c

             The evidence for g1 and g2 is a superclass evidence term: 

               g1 := sc w1, g2 := sc w2

     Step 2: The givens will solve the wanted w3, so that 
               w3 := sym (sc w1) ; sc w2 
                  
     Step 3: Now, one may naively assume that then w2 can be solve from w1
             after rewriting with the (now solved equality) (b ~ c). 
             
             But this rewriting is ruled out by the isGoodRectDict! 

Conclusion, we will (correctly) end up with the unsolved goals 
    (C a b, C a c)   

NB: The desugarer needs be more clever to deal with equalities 
    that participate in recursive dictionary bindings. 

\begin{code}
data LookupInstResult
  = NoInstance
  | GenInst [WantedEvVar] EvTerm 

matchClassInst :: InertSet -> Class -> [Type] -> WantedLoc -> TcS LookupInstResult
matchClassInst inerts clas tys loc
   = do { let pred = mkClassPred clas tys 
        ; mb_result <- matchClass clas tys
        ; untch <- getUntouchables
        ; case mb_result of
            MatchInstNo   -> return NoInstance
            MatchInstMany -> return NoInstance -- defer any reactions of a multitude until
                                               -- we learn more about the reagent 
            MatchInstSingle (_,_)
              | given_overlap untch -> 
                  do { traceTcS "Delaying instance application" $ 
                       vcat [ text "Workitem=" <+> pprType (mkClassPred clas tys)
                            , text "Relevant given dictionaries=" <+> ppr givens_for_this_clas ]
                     ; return NoInstance -- see Note [Instance and Given overlap]
                     }

            MatchInstSingle (dfun_id, mb_inst_tys) ->
              do { checkWellStagedDFun pred dfun_id loc

 	-- It's possible that not all the tyvars are in
	-- the substitution, tenv. For example:
	--	instance C X a => D X where ...
	-- (presumably there's a functional dependency in class C)
	-- Hence mb_inst_tys :: Either TyVar TcType 

                 ; tys <- instDFunTypes mb_inst_tys
                 ; let (theta, _) = tcSplitPhiTy (applyTys (idType dfun_id) tys)
                 ; if null theta then
                       return (GenInst [] (EvDFunApp dfun_id tys []))
                   else do
                     { evc_vars <- instDFunConstraints theta (Wanted loc)
                     ; let ev_vars = map evc_the_evvar evc_vars
                           new_evc_vars = filter isNewEvVar evc_vars 
                           wevs = map (\v -> EvVarX (evc_the_evvar v) loc) new_evc_vars
                                  -- wevs are only the real new variables that can be emitted 
                     ; return $ GenInst wevs (EvDFunApp dfun_id tys ev_vars) }
                 }
        }
   where 
     givens_for_this_clas :: Cts
     givens_for_this_clas 
         = lookupUFM (cts_given (inert_dicts inerts)) clas `orElse` emptyCts

     given_overlap :: TcsUntouchables -> Bool
     given_overlap untch = anyBag (matchable untch) givens_for_this_clas

     matchable untch (CDictCan { cc_class = clas_g, cc_tyargs = sys, cc_flavor = fl })
       | Just GivenOrig <- isGiven_maybe fl
       = ASSERT( clas_g == clas )
         case tcUnifyTys (\tv -> if isTouchableMetaTyVar_InRange untch tv && 
                                    tv `elemVarSet` tyVarsOfTypes tys
                                 then BindMe else Skolem) tys sys of
       -- We can't learn anything more about any variable at this point, so the only
       -- cause of overlap can be by an instantiation of a touchable unification
       -- variable. Hence we only bind touchable unification variables. In addition,
       -- we use tcUnifyTys instead of tcMatchTys to rule out cyclic substitutions.
            Nothing -> False
            Just _  -> True
       | otherwise = False -- No overlap with a solved, already been taken care of 
                           -- by the overlap check with the instance environment.
     matchable _tys ct = pprPanic "Expecting dictionary!" (ppr ct)
\end{code}

Note [Instance and Given overlap]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Assume that we have an inert set that looks as follows:
       [Given] D [Int]
And an instance declaration: 
       instance C a => D [a]
A new wanted comes along of the form: 
       [Wanted] D [alpha]

One possibility is to apply the instance declaration which will leave us 
with an unsolvable goal (C alpha). However, later on a new constraint may 
arise (for instance due to a functional dependency between two later dictionaries), 
that will add the equality (alpha ~ Int), in which case our ([Wanted] D [alpha]) 
will be transformed to [Wanted] D [Int], which could have been discharged by the given. 

The solution is that in matchClassInst and eventually in topReact, we get back with 
a matching instance, only when there is no Given in the inerts which is unifiable to
this particular dictionary.

The end effect is that, much as we do for overlapping instances, we delay choosing a 
class instance if there is a possibility of another instance OR a given to match our 
constraint later on. This fixes bugs #4981 and #5002.

This is arguably not easy to appear in practice due to our aggressive prioritization 
of equality solving over other constraints, but it is possible. I've added a test case 
in typecheck/should-compile/GivenOverlapping.hs

Moreover notice that our goals here are different than the goals of the top-level 
overlapping checks. There we are interested in validating the following principle:
 
    If we inline a function f at a site where the same global instance environment
    is available as the instance environment at the definition site of f then we 
    should get the same behaviour. 

But for the Given Overlap check our goal is just related to completeness of 
constraint solving. 




