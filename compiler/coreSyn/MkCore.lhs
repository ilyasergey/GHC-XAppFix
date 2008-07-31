\begin{code}
-- | Handy functions for creating much Core syntax
module MkCore (
        -- * Constructing normal syntax
        mkCoreLet, mkCoreLets,
        mkCoreApp, mkCoreApps, mkCoreConApps,
        mkCoreLams,
        
        -- * Constructing boxed literals
        mkWordExpr,
        mkIntExpr, mkIntegerExpr,
        mkFloatExpr, mkDoubleExpr,
        mkCharExpr, mkStringExpr, mkStringExprFS,
        
        -- * Constructing general big tuples
        -- $big_tuples
        mkChunkified,
        
        -- * Constructing small tuples
        mkCoreVarTup, mkCoreVarTupTy,
        mkCoreTup, mkCoreTupTy,
        
        -- * Constructing big tuples
        mkBigCoreVarTup, mkBigCoreVarTupTy,
        mkBigCoreTup, mkBigCoreTupTy,
        
        -- * Deconstructing small tuples
        mkSmallTupleSelector, mkSmallTupleCase,
        
        -- * Deconstructing big tuples
        mkTupleSelector, mkTupleCase,
        
        -- * Constructing list expressions
        mkNilExpr, mkConsExpr, mkListExpr, 
        mkFoldrExpr, mkBuildExpr
    ) where

#include "HsVersions.h"

import Id
import Var      ( setTyVarUnique )

import CoreSyn
import CoreUtils        ( exprType, needsCaseBinding, bindNonRec )
import Literal
import HscTypes

import TysWiredIn
import PrelNames
import MkId             ( seqId )

import Type
import TypeRep
import TysPrim          ( alphaTyVar )
import DataCon          ( DataCon, dataConWorkId )

import FastString
import UniqSupply
import BasicTypes
import Util             ( notNull, zipEqual )
import Panic
import Constants

import Data.Char        ( ord )
import Data.Word

infixl 4 `mkCoreApp`, `mkCoreApps`
\end{code}

%************************************************************************
%*                                                                      *
\subsection{Basic CoreSyn construction}
%*                                                                      *
%************************************************************************

\begin{code}
-- | Bind a binding group over an expression, using a @let@ or @case@ as
-- appropriate (see "CoreSyn#let_app_invariant")
mkCoreLet :: CoreBind -> CoreExpr -> CoreExpr
mkCoreLet (NonRec bndr rhs) body        -- See Note [CoreSyn let/app invariant]
  | needsCaseBinding (idType bndr) rhs
  = Case rhs bndr (exprType body) [(DEFAULT,[],body)]
mkCoreLet bind body
  = Let bind body

-- | Bind a list of binding groups over an expression. The leftmost binding
-- group becomes the outermost group in the resulting expression
mkCoreLets :: [CoreBind] -> CoreExpr -> CoreExpr
mkCoreLets binds body = foldr mkCoreLet body binds

-- | Construct an expression which represents the application of one expression
-- to the other
mkCoreApp :: CoreExpr -> CoreExpr -> CoreExpr
-- Check the invariant that the arg of an App is ok-for-speculation if unlifted
-- See CoreSyn Note [CoreSyn let/app invariant]
mkCoreApp fun (Type ty) = App fun (Type ty)
mkCoreApp fun arg       = mk_val_app fun arg arg_ty res_ty
                      where
                        (arg_ty, res_ty) = splitFunTy (exprType fun)

-- | Construct an expression which represents the application of a number of
-- expressions to another. The leftmost expression in the list is applied first
mkCoreApps :: CoreExpr -> [CoreExpr] -> CoreExpr
-- Slightly more efficient version of (foldl mkCoreApp)
mkCoreApps fun args
  = go fun (exprType fun) args
  where
    go fun _      []               = fun
    go fun fun_ty (Type ty : args) = go (App fun (Type ty)) (applyTy fun_ty ty) args
    go fun fun_ty (arg     : args) = go (mk_val_app fun arg arg_ty res_ty) res_ty args
                                   where
                                     (arg_ty, res_ty) = splitFunTy fun_ty

-- | Construct an expression which represents the application of a number of
-- expressions to that of a data constructor expression. The leftmost expression
-- in the list is applied first
mkCoreConApps :: DataCon -> [CoreExpr] -> CoreExpr
mkCoreConApps con args = mkCoreApps (Var (dataConWorkId con)) args

-----------
mk_val_app :: CoreExpr -> CoreExpr -> Type -> Type -> CoreExpr
mk_val_app (Var f `App` Type ty1 `App` Type _ `App` arg1) arg2 _ res_ty
  | f == seqId                -- Note [Desugaring seq (1), (2)]
  = Case arg1 case_bndr res_ty [(DEFAULT,[],arg2)]
  where
    case_bndr = case arg1 of
                   Var v1 | isLocalId v1 -> v1        -- Note [Desugaring seq (2) and (3)]
                   _                            -> mkWildId ty1

mk_val_app fun arg arg_ty _        -- See Note [CoreSyn let/app invariant]
  | not (needsCaseBinding arg_ty arg)
  = App fun arg                -- The vastly common case

mk_val_app fun arg arg_ty res_ty
  = Case arg (mkWildId arg_ty) res_ty [(DEFAULT,[],App fun (Var arg_id))]
  where
    arg_id = mkWildId arg_ty        -- Lots of shadowing, but it doesn't matter,
                                -- because 'fun ' should not have a free wild-id
\end{code}

Note [Desugaring seq (1)]  cf Trac #1031
~~~~~~~~~~~~~~~~~~~~~~~~~
   f x y = x `seq` (y `seq` (# x,y #))

The [CoreSyn let/app invariant] means that, other things being equal, because 
the argument to the outer 'seq' has an unlifted type, we'll use call-by-value thus:

   f x y = case (y `seq` (# x,y #)) of v -> x `seq` v

But that is bad for two reasons: 
  (a) we now evaluate y before x, and 
  (b) we can't bind v to an unboxed pair

Seq is very, very special!  So we recognise it right here, and desugar to
        case x of _ -> case y of _ -> (# x,y #)

Note [Desugaring seq (2)]  cf Trac #2231
~~~~~~~~~~~~~~~~~~~~~~~~~
Consider
   let chp = case b of { True -> fst x; False -> 0 }
   in chp `seq` ...chp...
Here the seq is designed to plug the space leak of retaining (snd x)
for too long.

If we rely on the ordinary inlining of seq, we'll get
   let chp = case b of { True -> fst x; False -> 0 }
   case chp of _ { I# -> ...chp... }

But since chp is cheap, and the case is an alluring contet, we'll
inline chp into the case scrutinee.  Now there is only one use of chp,
so we'll inline a second copy.  Alas, we've now ruined the purpose of
the seq, by re-introducing the space leak:
    case (case b of {True -> fst x; False -> 0}) of
      I# _ -> ...case b of {True -> fst x; False -> 0}...

We can try to avoid doing this by ensuring that the binder-swap in the
case happens, so we get his at an early stage:
   case chp of chp2 { I# -> ...chp2... }
But this is fragile.  The real culprit is the source program.  Perhaps we
should have said explicitly
   let !chp2 = chp in ...chp2...

But that's painful.  So the code here does a little hack to make seq
more robust: a saturated application of 'seq' is turned *directly* into
the case expression. So we desugar to:
   let chp = case b of { True -> fst x; False -> 0 }
   case chp of chp { I# -> ...chp... }
Notice the shadowing of the case binder! And now all is well.

The reason it's a hack is because if you define mySeq=seq, the hack
won't work on mySeq.  

Note [Desugaring seq (3)] cf Trac #2409
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The isLocalId ensures that we don't turn 
        True `seq` e
into
        case True of True { ... }
which stupidly tries to bind the datacon 'True'. 
\begin{code}
-- The functions from this point don't really do anything cleverer than
-- their counterparts in CoreSyn, but they are here for consistency

-- | Create a lambda where the given expression has a number of variables
-- bound over it. The leftmost binder is that bound by the outermost
-- lambda in the result
mkCoreLams :: [CoreBndr] -> CoreExpr -> CoreExpr
mkCoreLams = mkLams
\end{code}

%************************************************************************
%*                                                                      *
\subsection{Making literals}
%*                                                                      *
%************************************************************************

\begin{code}
-- | Create a 'CoreExpr' which will evaluate to the given @Int@
mkIntExpr      :: Int        -> CoreExpr            -- Result = I# i :: Int
mkIntExpr  i = mkConApp intDataCon  [mkIntLitInt i]

-- | Create a 'CoreExpr' which will evaluate to the given @Word@
mkWordExpr     :: Word       -> CoreExpr
mkWordExpr w = mkConApp wordDataCon [mkWordLitWord w]

-- | Create a 'CoreExpr' which will evaluate to the given @Integer@
mkIntegerExpr  :: MonadThings m => Integer    -> m CoreExpr  -- Result :: Integer
mkIntegerExpr i
  | inIntRange i        -- Small enough, so start from an Int
    = do integer_id <- lookupId smallIntegerName
         return (mkSmallIntegerLit integer_id i)

-- Special case for integral literals with a large magnitude:
-- They are transformed into an expression involving only smaller
-- integral literals. This improves constant folding.

  | otherwise = do       -- Big, so start from a string
      plus_id <- lookupId plusIntegerName
      times_id <- lookupId timesIntegerName
      integer_id <- lookupId smallIntegerName
      let
           lit i = mkSmallIntegerLit integer_id i
           plus a b  = Var plus_id  `App` a `App` b
           times a b = Var times_id `App` a `App` b

           -- Transform i into (x1 + (x2 + (x3 + (...) * b) * b) * b) with abs xi <= b
           horner :: Integer -> Integer -> CoreExpr
           horner b i | abs q <= 1 = if r == 0 || r == i 
                                     then lit i 
                                     else lit r `plus` lit (i-r)
                      | r == 0     =               horner b q `times` lit b
                      | otherwise  = lit r `plus` (horner b q `times` lit b)
                      where
                        (q,r) = i `quotRem` b

      return (horner tARGET_MAX_INT i)
  where
    mkSmallIntegerLit :: Id -> Integer -> CoreExpr
    mkSmallIntegerLit small_integer i = mkApps (Var small_integer) [mkIntLit i]


-- | Create a 'CoreExpr' which will evaluate to the given @Float@
mkFloatExpr :: Float -> CoreExpr
mkFloatExpr f = mkConApp floatDataCon [mkFloatLitFloat f]

-- | Create a 'CoreExpr' which will evaluate to the given @Double@
mkDoubleExpr :: Double -> CoreExpr
mkDoubleExpr d = mkConApp doubleDataCon [mkDoubleLitDouble d]


-- | Create a 'CoreExpr' which will evaluate to the given @Char@
mkCharExpr     :: Char             -> CoreExpr      -- Result = C# c :: Int
mkCharExpr c = mkConApp charDataCon [mkCharLit c]

-- | Create a 'CoreExpr' which will evaluate to the given @String@
mkStringExpr   :: MonadThings m => String     -> m CoreExpr  -- Result :: String
-- | Create a 'CoreExpr' which will evaluate to a string morally equivalent to the given @FastString@
mkStringExprFS :: MonadThings m => FastString -> m CoreExpr  -- Result :: String

mkStringExpr str = mkStringExprFS (mkFastString str)

mkStringExprFS str
  | nullFS str
  = return (mkNilExpr charTy)

  | lengthFS str == 1
  = do let the_char = mkCharExpr (headFS str)
       return (mkConsExpr charTy the_char (mkNilExpr charTy))

  | all safeChar chars
  = do unpack_id <- lookupId unpackCStringName
       return (App (Var unpack_id) (Lit (MachStr str)))

  | otherwise
  = do unpack_id <- lookupId unpackCStringUtf8Name
       return (App (Var unpack_id) (Lit (MachStr str)))

  where
    chars = unpackFS str
    safeChar c = ord c >= 1 && ord c <= 0x7F
\end{code}

%************************************************************************
%*                                                                      *
\subsection{Tuple constructors}
%*                                                                      *
%************************************************************************

\begin{code}

-- $big_tuples
-- #big_tuples#
--
-- GHCs built in tuples can only go up to 'mAX_TUPLE_SIZE' in arity, but
-- we might concievably want to build such a massive tuple as part of the
-- output of a desugaring stage (notably that for list comprehensions).
--
-- We call tuples above this size \"big tuples\", and emulate them by
-- creating and pattern matching on >nested< tuples that are expressible
-- by GHC.
--
-- Nesting policy: it's better to have a 2-tuple of 10-tuples (3 objects)
-- than a 10-tuple of 2-tuples (11 objects), so we want the leaves of any
-- construction to be big.
--
-- If you just use the 'mkBigCoreTup', 'mkBigCoreVarTupTy', 'mkTupleSelector'
-- and 'mkTupleCase' functions to do all your work with tuples you should be
-- fine, and not have to worry about the arity limitation at all.

-- | Lifts a \"small\" constructor into a \"big\" constructor by recursive decompositon
mkChunkified :: ([a] -> a)      -- ^ \"Small\" constructor function, of maximum input arity 'mAX_TUPLE_SIZE'
             -> [a]             -- ^ Possible \"big\" list of things to construct from
             -> a               -- ^ Constructed thing made possible by recursive decomposition
mkChunkified small_tuple as = mk_big_tuple (chunkify as)
  where
	-- Each sub-list is short enough to fit in a tuple
    mk_big_tuple [as] = small_tuple as
    mk_big_tuple as_s = mk_big_tuple (chunkify (map small_tuple as_s))

chunkify :: [a] -> [[a]]
-- ^ Split a list into lists that are small enough to have a corresponding
-- tuple arity. The sub-lists of the result all have length <= 'mAX_TUPLE_SIZE'
-- But there may be more than 'mAX_TUPLE_SIZE' sub-lists
chunkify xs
  | n_xs <= mAX_TUPLE_SIZE = [xs] 
  | otherwise		   = split xs
  where
    n_xs     = length xs
    split [] = []
    split xs = take mAX_TUPLE_SIZE xs : split (drop mAX_TUPLE_SIZE xs)
    
\end{code}

Creating tuples and their types for Core expressions 

@mkBigCoreVarTup@ builds a tuple; the inverse to @mkTupleSelector@.  

* If it has only one element, it is the identity function.

* If there are more elements than a big tuple can have, it nests 
  the tuples.  

\begin{code}

-- | Build a small tuple holding the specified variables
mkCoreVarTup :: [Id] -> CoreExpr
mkCoreVarTup ids = mkCoreTup (map Var ids)

-- | Bulid the type of a small tuple that holds the specified variables
mkCoreVarTupTy :: [Id] -> Type
mkCoreVarTupTy ids = mkCoreTupTy (map idType ids)

-- | Build a small tuple holding the specified expressions
mkCoreTup :: [CoreExpr] -> CoreExpr
mkCoreTup []  = Var unitDataConId
mkCoreTup [c] = c
mkCoreTup cs  = mkConApp (tupleCon Boxed (length cs))
                         (map (Type . exprType) cs ++ cs)

-- | Build the type of a small tuple that holds the specified type of thing
mkCoreTupTy :: [Type] -> Type
mkCoreTupTy [ty] = ty
mkCoreTupTy tys  = mkTupleTy Boxed (length tys) tys


-- | Build a big tuple holding the specified variables
mkBigCoreVarTup :: [Id] -> CoreExpr
mkBigCoreVarTup ids = mkBigCoreTup (map Var ids)

-- | Build the type of a big tuple that holds the specified variables
mkBigCoreVarTupTy :: [Id] -> Type
mkBigCoreVarTupTy ids = mkBigCoreTupTy (map idType ids)

-- | Build a big tuple holding the specified expressions
mkBigCoreTup :: [CoreExpr] -> CoreExpr
mkBigCoreTup = mkChunkified mkCoreTup

-- | Build the type of a big tuple that holds the specified type of thing
mkBigCoreTupTy :: [Type] -> Type
mkBigCoreTupTy = mkChunkified mkCoreTupTy
\end{code}

%************************************************************************
%*                                                                      *
\subsection{Tuple destructors}
%*                                                                      *
%************************************************************************

\begin{code}
-- | Builds a selector which scrutises the given
-- expression and extracts the one name from the list given.
-- If you want the no-shadowing rule to apply, the caller
-- is responsible for making sure that none of these names
-- are in scope.
--
-- If there is just one 'Id' in the tuple, then the selector is
-- just the identity.
--
-- If necessary, we pattern match on a \"big\" tuple.
mkTupleSelector :: [Id]         -- ^ The 'Id's to pattern match the tuple against
                -> Id           -- ^ The 'Id' to select
                -> Id           -- ^ A variable of the same type as the scrutinee
                -> CoreExpr     -- ^ Scrutinee
                -> CoreExpr     -- ^ Selector expression

-- mkTupleSelector [a,b,c,d] b v e
--          = case e of v { 
--                (p,q) -> case p of p {
--                           (a,b) -> b }}
-- We use 'tpl' vars for the p,q, since shadowing does not matter.
--
-- In fact, it's more convenient to generate it innermost first, getting
--
--        case (case e of v 
--                (p,q) -> p) of p
--          (a,b) -> b
mkTupleSelector vars the_var scrut_var scrut
  = mk_tup_sel (chunkify vars) the_var
  where
    mk_tup_sel [vars] the_var = mkSmallTupleSelector vars the_var scrut_var scrut
    mk_tup_sel vars_s the_var = mkSmallTupleSelector group the_var tpl_v $
                                mk_tup_sel (chunkify tpl_vs) tpl_v
        where
          tpl_tys = [mkCoreTupTy (map idType gp) | gp <- vars_s]
          tpl_vs  = mkTemplateLocals tpl_tys
          [(tpl_v, group)] = [(tpl,gp) | (tpl,gp) <- zipEqual "mkTupleSelector" tpl_vs vars_s,
                                         the_var `elem` gp ]
\end{code}

\begin{code}
-- | Like 'mkTupleSelector' but for tuples that are guaranteed
-- never to be \"big\".
--
-- > mkSmallTupleSelector [x] x v e = [| e |]
-- > mkSmallTupleSelector [x,y,z] x v e = [| case e of v { (x,y,z) -> x } |]
mkSmallTupleSelector :: [Id]        -- The tuple args
          -> Id         -- The selected one
          -> Id         -- A variable of the same type as the scrutinee
          -> CoreExpr        -- Scrutinee
          -> CoreExpr
mkSmallTupleSelector [var] should_be_the_same_var _ scrut
  = ASSERT(var == should_be_the_same_var)
    scrut
mkSmallTupleSelector vars the_var scrut_var scrut
  = ASSERT( notNull vars )
    Case scrut scrut_var (idType the_var)
         [(DataAlt (tupleCon Boxed (length vars)), vars, Var the_var)]
\end{code}

\begin{code}
-- | A generalization of 'mkTupleSelector', allowing the body
-- of the case to be an arbitrary expression.
--
-- To avoid shadowing, we use uniques to invent new variables.
--
-- If necessary we pattern match on a \"big\" tuple.
mkTupleCase :: UniqSupply       -- ^ For inventing names of intermediate variables
            -> [Id]             -- ^ The tuple identifiers to pattern match on
            -> CoreExpr         -- ^ Body of the case
            -> Id               -- ^ A variable of the same type as the scrutinee
            -> CoreExpr         -- ^ Scrutinee
            -> CoreExpr
-- ToDo: eliminate cases where none of the variables are needed.
--
--         mkTupleCase uniqs [a,b,c,d] body v e
--           = case e of v { (p,q) ->
--             case p of p { (a,b) ->
--             case q of q { (c,d) ->
--             body }}}
mkTupleCase uniqs vars body scrut_var scrut
  = mk_tuple_case uniqs (chunkify vars) body
  where
    -- This is the case where don't need any nesting
    mk_tuple_case _ [vars] body
      = mkSmallTupleCase vars body scrut_var scrut
      
    -- This is the case where we must make nest tuples at least once
    mk_tuple_case us vars_s body
      = let (us', vars', body') = foldr one_tuple_case (us, [], body) vars_s
            in mk_tuple_case us' (chunkify vars') body'
    
    one_tuple_case chunk_vars (us, vs, body)
      = let (us1, us2) = splitUniqSupply us
            scrut_var = mkSysLocal (fsLit "ds") (uniqFromSupply us1)
              (mkCoreTupTy (map idType chunk_vars))
            body' = mkSmallTupleCase chunk_vars body scrut_var (Var scrut_var)
        in (us2, scrut_var:vs, body')
\end{code}

\begin{code}
-- | As 'mkTupleCase', but for a tuple that is small enough to be guaranteed
-- not to need nesting.
mkSmallTupleCase
        :: [Id]         -- ^ The tuple args
        -> CoreExpr     -- ^ Body of the case
        -> Id           -- ^ A variable of the same type as the scrutinee
        -> CoreExpr     -- ^ Scrutinee
        -> CoreExpr

mkSmallTupleCase [var] body _scrut_var scrut
  = bindNonRec var scrut body
mkSmallTupleCase vars body scrut_var scrut
-- One branch no refinement?
  = Case scrut scrut_var (exprType body) [(DataAlt (tupleCon Boxed (length vars)), vars, body)]
\end{code}

%************************************************************************
%*                                                                      *
\subsection{Common list manipulation expressions}
%*                                                                      *
%************************************************************************

Call the constructor Ids when building explicit lists, so that they
interact well with rules.

\begin{code}
-- | Makes a list @[]@ for lists of the specified type
mkNilExpr :: Type -> CoreExpr
mkNilExpr ty = mkConApp nilDataCon [Type ty]

-- | Makes a list @(:)@ for lists of the specified type
mkConsExpr :: Type -> CoreExpr -> CoreExpr -> CoreExpr
mkConsExpr ty hd tl = mkConApp consDataCon [Type ty, hd, tl]

-- | Make a list containing the given expressions, where the list has the given type
mkListExpr :: Type -> [CoreExpr] -> CoreExpr
mkListExpr ty xs = foldr (mkConsExpr ty) (mkNilExpr ty) xs

-- | Make a fully applied 'foldr' expression
mkFoldrExpr :: MonadThings m
            => Type             -- ^ Element type of the list
            -> Type             -- ^ Fold result type
            -> CoreExpr         -- ^ "Cons" function expression for the fold
            -> CoreExpr         -- ^ "Nil" expression for the fold
            -> CoreExpr         -- ^ List expression being folded acress
            -> m CoreExpr
mkFoldrExpr elt_ty result_ty c n list = do
    foldr_id <- lookupId foldrName
    return (Var foldr_id `App` Type elt_ty 
           `App` Type result_ty
           `App` c
           `App` n
           `App` list)

-- | Make a 'build' expression applied to a locally-bound worker function
mkBuildExpr :: (MonadThings m, MonadUnique m)
            => Type                                     -- ^ Type of list elements to be built
            -> ((Id, Type) -> (Id, Type) -> m CoreExpr) -- ^ Function that, given information about the 'Id's
                                                        -- of the binders for the build worker function, returns
                                                        -- the body of that worker
            -> m CoreExpr
mkBuildExpr elt_ty mk_build_inside = do
    [n_tyvar] <- newTyVars [alphaTyVar]
    let n_ty = mkTyVarTy n_tyvar
        c_ty = mkFunTys [elt_ty, n_ty] n_ty
    [c, n] <- sequence [mkSysLocalM (fsLit "c") c_ty, mkSysLocalM (fsLit "n") n_ty]
    
    build_inside <- mk_build_inside (c, c_ty) (n, n_ty)
    
    build_id <- lookupId buildName
    return $ Var build_id `App` Type elt_ty `App` mkLams [n_tyvar, c, n] build_inside
  where
    newTyVars tyvar_tmpls = do
      uniqs <- getUniquesM
      return (zipWith setTyVarUnique tyvar_tmpls uniqs)
\end{code}