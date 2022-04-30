{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}

module VerifPal.Check where

import VerifPal.Types

import Control.Monad.State
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Debug.Trace
import Data.Graph.Inductive

import System.IO.Unsafe (unsafePerformIO)
--import Data.Graph.Inductive.Graph (mkGraph, LNode, LEdge, OrdGr, DynGraph, empty, Graph)
--import Data.Graph.Inductive.PatriciaTree

data ModelError
  = OverlappingConstant Constant Text
  | MissingConstant Constant Text
  | NotImplemented Text
  deriving (Eq, Ord, Show)

-- graph mapping constants to the expressions that *directly* contain them
-- expressions are either obtained
--
-- attacker obtains constants either through:
-- Knowledge Leaks
-- Message Constant where
--   msConstants[Constant] =
--     ( (Assignment Expr)) that can be unlocked

data ModelState = ModelState
  { msConstants          :: Map Constant Knowledge
  , msPrincipalConstants :: Map PrincipalName (Map Constant (Knowledge, ProcessingCounter))
  , msProcessingCounter  :: ProcessingCounter
  , msErrors             :: [ModelError]
  , msQueryResults       :: [(Query, Bool)]
  } deriving (Eq, Ord, Show)

type ProcessingCounter = Int

-- Everyone knows the magic constant "nil" TODO reference manual?
emptyConstantMap = Map.fromList [
  (Constant {constantName="nil"}, Public)
  ]

emptyPrincipalConstantMap = Map.fromList [
  (Constant {constantName="nil"}, (Public,0))
  ]

emptyModelState :: ModelState
emptyModelState = ModelState
  { msConstants = emptyConstantMap
  , msPrincipalConstants = Map.empty
  , msProcessingCounter = 0
  , msErrors = []
  , msQueryResults = []
  }

type EvalM a = State ModelState a

-- TODO: Check if constants are unique
-- TODO: Check if a given variable is fresh

process :: Model -> ModelState
process model =
  let m = execState (processM model) emptyModelState
      () = unsafePerformIO (putStrLn "yo")
  in
    let vertices = [] :: [(Node, Int)]
        edges = []  :: [LEdge Int]
        g = mkGraph (vertices)
                    (edges) :: Gr Int Int
    in
      m

processM :: Model -> State ModelState ()
processM Model{..} =
  mapM_ processModelPart modelParts

processModelPart :: ModelPart -> State ModelState ()
processModelPart (ModelPrincipal (Principal name knows)) = do
  mapM_ (processKnowledge name) knows
processModelPart (ModelQueries qs) = do
  -- TODO if the user wrote the same query twice
  -- we should collapse them to a single query
  -- and probably issue a warning?
  mapM_ processQuery qs

processModelPart (ModelMessage (Message sender receiver consts)) = do
  forM_ consts $ \(cconst,cguard) -> do
    -- check the sender knows all the constants being sent:
    hasPrincipalConstantOrError sender cconst "sender reference to unknown constant"
    -- add them to the knowledge of the receiver so they know them too:
    maybeknowledge <- getConstant cconst
    case maybeknowledge of
      Nothing -> pure ()
      Just knowledge -> upsertPrincipalConstant receiver cconst knowledge
    -- TODO add consts to attacker knowledge

processModelPart (ModelPhase (Phase {..})) = do
  pure ()

processKnowledge :: PrincipalName -> (Constant, Knowledge) -> State ModelState ()
processKnowledge principalName (constant, knowledge) = do
  -- we need to consider three "knowledges":
  -- 1) does it exist anywhere
  -- 2) does this principal know about it
  -- 3) does the attacker know about it?
  existingConstant <- getConstant constant
  case (existingConstant, knowledge) of
    (Nothing, Public) -> addConstant principalName constant knowledge
    (Nothing, Private) -> addConstant principalName constant knowledge
    (Nothing, Password) -> addConstant principalName constant knowledge
    (Nothing, Generates) -> addConstant principalName constant knowledge
    (Nothing, Assignment exp) ->
      if constant == Constant{constantName="_"}
      then pure ()
      -- For assignments we check that all the referenced constants exist
      -- in the knowledge map associated with the current principal.
      -- The ambition is to catch both references to undefined constants (typos)
      -- and cases where a reference is made to a constant that exists, but it isn't
      -- known by (principalName):
      else
        foldConstantsInExpr (addConstant principalName constant knowledge)
        exp (\c st -> do
                st >>= pure (hasPrincipalConstantOrError principalName c "assignment to unbound constant")
            )
    (Just _, Generates) -> addError (OverlappingConstant constant "can't generate the same thing twice")
    (Just _, Assignment _) -> addError (OverlappingConstant constant "can't assign to the same name twice")
    (_, Leaks) ->
      -- TODO give it to the attacker
      modifyConstant principalName constant Leaks
    (Just existingKnowledge, _) ->
      if existingKnowledge == knowledge
      then upsertPrincipalConstant principalName constant knowledge
      else addError (OverlappingConstant constant "can't generate the same thing twice")

processQuery :: Query -> State ModelState ()
processQuery query@(Query (FreshnessQuery constant) queryOptions) = do
  constantExistsOrError constant
  cs <- gets msConstants ;
  addQueryResult query $ mapConstants False constant (
    \c a -> a || Just Generates == Map.lookup c cs) cs

processQuery (Query (ConfidentialityQuery constant) queryOptions) = do
  constantExistsOrError constant
  addError (NotImplemented "confidentiality query not implemented") -- FIXME

processQuery (Query (UnlinkabilityQuery consts) queryOptions) = do
  forM_ consts $ \cconst -> do constantExistsOrError cconst
  addError (NotImplemented "unlinkability query not implemented") -- FIXME

processQuery (Query (AuthenticationQuery msg) queryOptions) = do
  addError (NotImplemented "authentication query not implemented") -- FIXME

processQuery query@(Query (EquivalenceQuery consts@(c1:cs)) queryOptions) = do
  forM_ consts $ \cconst -> do
    constantExistsOrError cconst
  constmap <- gets msConstants ;
  let (_, result) = (foldl (\(c1,result) c2 ->
                              let x2 = canonicalizeExpr constmap (EConstant c2) in
                                (c1, result && equivalenceExpr c1 x2)
                           )(canonicalizeExpr constmap (EConstant (c1)), True) consts)
    in
    addQueryResult query $ result

getConstant :: Constant -> State ModelState (Maybe Knowledge)
getConstant constant = gets $ Map.lookup constant . msConstants

canOverlap :: Knowledge -> Bool
canOverlap = \case
  Private -> True
  Public -> True
  Password -> True
  Leaks -> True
  Generates -> False
  Assignment _ -> False

addQueryResult :: Query -> Bool -> State ModelState ()
addQueryResult query result = modify $ \state ->
  state { msQueryResults = msQueryResults state <> [(query, result)] }

hasConstant :: Constant -> Knowledge -> State ModelState Bool
hasConstant constant knows1 = do
  knows2 <- getConstant constant
  pure (Just knows1 == knows2)

hasPrincipalConstant :: PrincipalName -> Constant -> State ModelState Bool
hasPrincipalConstant principalName constant = do
  currentCount <- getCounter
  principalMap <- gets (fromMaybe emptyPrincipalConstantMap . Map.lookup principalName . msPrincipalConstants)
  case Map.lookup constant principalMap of
    Just (know, cou) | cou <= currentCount -> pure True
    Just _ -> pure False -- not yet
    Nothing -> pure False

hasPrincipalConstantOrError :: PrincipalName -> Constant -> Text -> State ModelState ()
hasPrincipalConstantOrError principalName refconstant errorText = do
  (\() ->
     do xy <- hasPrincipalConstant principalName refconstant
        if xy
          then pure ()
          else addError (MissingConstant refconstant errorText)) ()

addConstant :: PrincipalName -> Constant -> Knowledge -> State ModelState ()
addConstant principalName constant knowledge = do
  existingConstant <- gets (Map.lookup constant . msConstants)
  case existingConstant of
    Just _ -> addError (OverlappingConstant constant "constant already defined")
    Nothing -> do
      upsertConstantBoth principalName constant knowledge

modifyConstant :: PrincipalName -> Constant -> Knowledge -> State ModelState ()
modifyConstant principalName constant knowledge = do
  existingConstant <- gets (Map.lookup constant . msConstants)
  case existingConstant of
    Nothing -> addError (MissingConstant constant "Can't modify non-existent constant")
    Just _ -> upsertConstantBoth principalName constant knowledge

upsertConstantBoth :: PrincipalName -> Constant -> Knowledge -> State ModelState ()
upsertConstantBoth principalName constant knowledge = do
  upsertConstant constant knowledge
  upsertPrincipalConstant principalName constant knowledge

upsertConstant :: Constant -> Knowledge -> State ModelState ()
upsertConstant constant knowledge =
  modify $ \state -> state { msConstants = Map.insert constant knowledge (msConstants state) }

upsertPrincipalConstant :: PrincipalName -> Constant -> Knowledge -> State ModelState ()
upsertPrincipalConstant principalName constant knowledge = do
  count <- getCounter
  principalMap <- gets (fromMaybe emptyPrincipalConstantMap . Map.lookup principalName . msPrincipalConstants)
  let newPrincipalMap = Map.insert constant (knowledge, count) principalMap
  modify $ \state -> state { msPrincipalConstants = Map.insert principalName newPrincipalMap (msPrincipalConstants state) }

getCounter :: State ModelState ProcessingCounter
getCounter = do
  count <- gets msProcessingCounter
  modify (\st -> st { msProcessingCounter = count + 1 })
  pure count

quicksort :: Ord a => [a] -> [a]
quicksort []     = []
quicksort (p:xs) = (quicksort lesser) ++ [p] ++ (quicksort greater)
    where
        lesser  = filter (< p) xs
        greater = filter (>= p) xs
-- equationToList is a sorted list of the expressions that constitute
-- the terms of an expression.
-- The idea is that G^x^y^z should give [x,y,z]
--              and G^z^y^x should give [x,y,z]
-- TODO this function relies on the assumption that
-- each equation contains exactly one G that sits at the base
-- of all the equations; we should typecheck that.
equationToList :: [CanonExpr] -> CanonExpr -> [CanonExpr]
equationToList acc c =
  case simplifyExpr c of
    -- special case: G^base^b: we strip the base TODO this is no good
    -- TODO because it may be DEC(x,ENC(x, G base)) which is also ok.
    --((:^^:) (CG base) (CG b)) -> equationToList (base:acc) b
    --((:^^:) base (CG b)) ->
      --quicksort (base : (map CG (equationToList [] b)) ++ acc)
    --((:^^:) (CG base) b) -> equationToList (base:acc) b
    -- x^y: recurse to see if x or y are themselves :^^:
    ((:^^:) lhs rhs) ->
      equationToList (equationToList acc lhs) rhs
    CG term | acc == [] ->
      quicksort (term:acc)
    CG term -> -- here we should lift the first term to G^:
      equationToList ((CConstant (Constant {constantName = "G"}) CPublic):acc) term
    -- term was not :^^: so it's just a term:
    term -> quicksort (term:acc)

simplifyExpr :: CanonExpr -> CanonExpr
simplifyExpr e = do
  case e of
    -- DEC(k, ENC(k, payload)) = payload
    CPrimitive (DEC key encrypted) hasq -> do
      let simple_enc = simplifyExpr encrypted
          simple_key = simplifyExpr key
      case simple_enc of
        -- remove the key:
        CPrimitive (ENC simple_key' payload) _
          | equivalenceExpr simple_key simple_key' -> simplifyExpr payload
        _ -> CPrimitive (DEC simple_key simple_enc) hasq
    CPrimitive (AEAD_DEC key encrypted ad) hasq -> do
      let simple_enc = simplifyExpr encrypted
          simple_key = simplifyExpr key
          simple_ad  = simplifyExpr ad
      case simple_enc of
        -- remove the dec(enc()) if key and ad match:
        CPrimitive (AEAD_ENC simple_key' payload simple_ad') _
          | equivalenceExpr simple_key simple_key' && equivalenceExpr simple_ad simple_ad' -> simplifyExpr payload
        _ -> CPrimitive (AEAD_DEC simple_key simple_enc simple_ad) hasq
    -- TODO may need: CPrimitive ep hasq -> CPrimitive (mapPrimitiveP ep simplifyExpr) hasq
    e -> e

equivalenceExpr' :: CanonExpr -> CanonExpr -> Bool
equivalenceExpr' o_e1 o_e2 =
  -- TODO it might be nice to memoize the results of these comparisons
  -- in a set in the future
  case (simplifyExpr o_e1, simplifyExpr o_e2) of
    -- Equations are kind of tricky:
    -- it needs to hold that G^a^x^y^z === G^z^a^y^x etc,
    -- the approach taken here is to sort the expressions (using Ord or whatever)
    -- and then compare them term by term:
    --
    --
    (CConstant c _, CConstant c' _) -> c == c'
    -- Below we have some transformations, they are all guarded to avoid shorting
    -- the match cases when they don't match.
    -- TODO it might be a better strategy to have a "minimizeExpr" function to do
    -- these; then we could reuse that to e.g. display things to the user?
    --
    -- Concat of a single value is equivalent to the value:
    (e, CPrimitive (CONCAT [e']) _) | equivalenceExpr e e' -> True
    -- Decryption of encrypted plaintext is equivalent to plaintext.
    -- (encrypted) may not immediately be an ENC, so we need to recurse:
    -- TODO this is not covered by simplifyExpr ? commenting out the part below fails the equivalence3.vp test:
    (e, CPrimitive (DEC key encrypted) _)
      | equivalenceExpr encrypted (CPrimitive (ENC key e) HasntQuestionMark) -> True
    --
    (CPrimitive p _, CPrimitive p' _) -> equivalencePrimitive p p'
    (CG e, CG e') -> equivalenceExpr e e'
    (a@((:^^:) {}), b@((:^^:) {})) ->
      equivalenceExprs
        (equationToList [] a)
        (equationToList [] b)
    (CPrimitive {}, _) -> False
    (CConstant {}, _ ) -> False
    (CG {}, _) -> False

equivalenceExpr :: CanonExpr -> CanonExpr -> Bool
equivalenceExpr e1 e2 = -- TODO cannot be bothered to do transformations both ways
  equivalenceExpr' e1 e2 || equivalenceExpr' e2 e1

equivalenceExprs :: [CanonExpr] -> [CanonExpr] -> Bool
equivalenceExprs [] [] = True
equivalenceExprs (x:xs) (y:ys) = equivalenceExpr x y && equivalenceExprs xs ys
equivalenceExprs _ _ = False

equivalencePrimitive :: PrimitiveP CanonExpr -> PrimitiveP CanonExpr -> Bool
equivalencePrimitive p1 p2 = do
  let eqExpr e1 e2 = equivalenceExpr e1 e2
  let eqExprs [] [] = True
      eqExprs (x:xs) (y:ys) = eqExpr x y && eqExprs xs ys
  case (p1, p2) of
    -- TODO is this the right place for this optimization?
    -- NOTE: we do not have any when-guards in here; this way we can
    -- ensure we always progress (by stripping a constructor) and don't
    -- end up in endless loops.
    -- we can however do simple transformations as long as we remove
    -- constructors:
    (CONCAT e, SPLIT (CPrimitive (CONCAT e') _TODO)) -> eqExprs e e'
    (SPLIT (CPrimitive (CONCAT e') _TODO), CONCAT e) -> eqExprs e e'
    -- simple equivalence: equivalent constructors, need to
    -- compare the leaf exprs:
    (ASSERT e1 e2, ASSERT e'1 e'2) ->
      eqExpr e1 e'1 && eqExpr e2 e'2
    (ASSERT {}, _) -> False
    (CONCAT e1, CONCAT e'1) -> eqExprs e1 e'1
    (CONCAT {}, _) -> False
    (SPLIT e, SPLIT e') -> eqExpr e e'
    (SPLIT {}, _) -> False
    (HASH e, HASH e') -> eqExprs e e'
    (HASH {}, _) -> False
    (MAC e1 e2, MAC e'1 e'2) -> eqExpr e1 e'1 && eqExpr e2 e'2
    (MAC {}, _) -> False
    (HKDF e1 e2 e3, HKDF e'1 e'2 e'3) ->
      eqExpr e1 e'1 && eqExpr e2 e'2 && eqExpr e3 e'3
    (HKDF {}, _) -> False
    (PW_HASH e, PW_HASH e') -> eqExprs e e'
    (PW_HASH {}, _) -> False
    (ENC e1 e2, ENC e'1 e'2) -> eqExpr e1 e'1 && eqExpr e2 e'2
    (ENC {}, _) -> False
    (DEC e1 e2, DEC e'1 e'2) -> eqExpr e1 e'1 && eqExpr e2 e'2
    (DEC {}, _) -> False
    (AEAD_ENC e1 e2 e3, AEAD_ENC e'1 e'2 e'3) ->
      eqExpr e1 e'1 && eqExpr e2 e'2 && eqExpr e3 e'3
    (AEAD_ENC {}, _) -> False
    (AEAD_DEC e1 e2 e3, AEAD_DEC e'1 e'2 e'3) ->
      eqExpr e1 e'1 && eqExpr e2 e'2 && eqExpr e3 e'3
    (AEAD_DEC {}, _) -> False
    (PKE_ENC e1 e2, PKE_ENC e'1 e'2) -> eqExpr e1 e'1 && eqExpr e2 e'2
    (PKE_ENC {}, _) -> False
    (PKE_DEC e1 e2, PKE_DEC e'1 e'2) -> eqExpr e1 e'1 && eqExpr e2 e'2
    (PKE_DEC {}, _) -> False
    (SIGN e1 e2, SIGN e'1 e'2) -> eqExpr e1 e'1 && eqExpr e2 e'2
    (SIGN {}, _) -> False
    (SIGNVERIF e1 e2 e3, SIGNVERIF e'1 e'2 e'3) ->
      eqExpr e1 e'1 && eqExpr e2 e'2 && eqExpr e3 e'3
    (SIGNVERIF {}, _) -> False
    (RINGSIGN e1 e2 e3 e4, RINGSIGN e'1 e'2 e'3 e'4) ->
      eqExpr e1 e'1 && eqExpr e2 e'2 && eqExpr e3 e'3 && eqExpr e4 e'4
    (RINGSIGN {}, _) -> False
    (RINGSIGNVERIF e1 e2 e3 e4 e5, RINGSIGNVERIF e'1 e'2 e'3 e'4 e'5) ->
      eqExpr e1 e'1 && eqExpr e2 e'2 && eqExpr e3 e'3 && eqExpr e4 e'4 && eqExpr e5 e'5
    (RINGSIGNVERIF {}, _) -> False
    (BLIND e1 e2, BLIND e'1 e'2) -> eqExpr e1 e'1 && eqExpr e2 e'2
    (BLIND {}, _) -> False
    (UNBLIND e1 e2 e3, UNBLIND e'1 e'2 e'3) ->
      eqExpr e1 e'1 && eqExpr e2 e'2 && eqExpr e3 e'3
    (UNBLIND {}, _) -> False
    (SHAMIR_SPLIT e, SHAMIR_SPLIT e') -> eqExpr e e'
    (SHAMIR_SPLIT {}, _) -> False
    (SHAMIR_JOIN e1 e2, SHAMIR_JOIN e'1 e'2) ->
      -- argument order is irrelevant here:
      let a = quicksort [ e1,  e2]
          b = quicksort [e'1, e'2]
      in
        eqExprs a b
    (SHAMIR_JOIN {}, _) -> False

canonicalizePrimitive :: Map Constant Knowledge -> Primitive -> PrimitiveP CanonExpr
canonicalizePrimitive m old =
  mapPrimitiveP old (canonicalizeExpr m)

data CanonExpr
  = CG CanonExpr
  | (:^^:) CanonExpr CanonExpr
  | CConstant Constant CanonKnowledge
  | CPrimitive (PrimitiveP CanonExpr) CheckedPrimitive
  deriving (Eq, Ord, Show)
data CanonKnowledge
  = CPrivate
  | CPublic
  | CGenerates
  | CPassword
  deriving (Eq, Ord, Show)
canonicalizeExpr :: Map Constant Knowledge -> Expr -> CanonExpr
canonicalizeExpr m orig_exp = do
  let self = canonicalizeExpr m
  case orig_exp of
    -- TODO we need special handling of G^y^x to G^x^y (sorted in order to check equivalence)
    G exp -> CG (self exp)
    (:^:) const exp -> (:^^:) (self (EConstant const)) (self exp)
    EConstant const ->
      case Map.lookup const m of
        Just Private -> CConstant const CPrivate
        Just Public -> CConstant const CPublic
        Just Generates -> CConstant const CGenerates
        Just Password -> CConstant const CPassword
        Just (Assignment exp) -> self exp
        Just (Received _) -> CConstant const CPublic -- TODO should never happen
        Just Leaks -> CConstant const CPublic -- TODO should never happen
        Nothing -> CConstant const CPublic -- TODO should never happen
    EPrimitive p cp -> CPrimitive (mapPrimitiveP p self) cp

mapPrimitiveP :: PrimitiveP a -> (a -> b) -> PrimitiveP b
mapPrimitiveP prim f =
  case prim of
    ASSERT e1 e2 -> ASSERT (f e1) (f e2)
    CONCAT exps -> CONCAT (map f exps)
    SPLIT exp -> SPLIT (f exp)
    HASH exps -> HASH (map f exps)
    MAC e1 e2 -> MAC (f e1) (f e2)
    HKDF e1 e2 e3 -> HKDF (f e1) (f e2) (f e3)
    PW_HASH exps -> PW_HASH (map f exps)
    ENC e1 e2 -> ENC (f e1) (f e2)
    DEC e1 e2 -> DEC (f e1) (f e2)
    AEAD_ENC e1 e2 e3 -> AEAD_ENC (f e1) (f e2) (f e3)
    AEAD_DEC e1 e2 e3 -> AEAD_DEC (f e1) (f e2) (f e3)
    PKE_ENC e1 e2 -> PKE_ENC (f e1) (f e2)
    PKE_DEC e1 e2 -> PKE_DEC (f e1) (f e2)
    SIGN e1 e2 -> SIGN (f e1) (f e2)
    SIGNVERIF e1 e2 e3 -> SIGNVERIF (f e1) (f e2) (f e3)
    RINGSIGN e1 e2 e3 e4 -> RINGSIGN (f e1) (f e2) (f e3) (f e4)
    RINGSIGNVERIF e1 e2 e3 e4 e5 -> RINGSIGNVERIF (f e1) (f e2) (f e3) (f e4) (f e5)
    BLIND e1 e2 -> BLIND (f e1) (f e2)
    UNBLIND e1 e2 e3 -> UNBLIND (f e1) (f e2) (f e3)
    SHAMIR_SPLIT e1 -> SHAMIR_SPLIT (f e1)
    SHAMIR_JOIN e1 e2 -> SHAMIR_JOIN (f e1) (f e2)

-- note that this ONLY folds over the constants in an expression,
-- NOT the knowledge maps, so it will not "jump" across maps of knowledge
-- from other principals.
foldConstantsInExpr :: acc -> Expr -> (Constant -> acc -> acc) -> acc
foldConstantsInExpr acc o_exp f =
  let dolist = foldl (\acc exp -> foldConstantsInExpr acc exp f) acc in
  case o_exp of
    G exp -> dolist [exp]
    (:^:) c exp -> foldConstantsInExpr (f c acc) exp f
    EConstant c -> f c acc
    EPrimitive prim _ ->
      case prim of
        ASSERT e1 e2 -> dolist [e1, e2]
        CONCAT exps -> dolist exps
        SPLIT exp -> dolist [exp]
        HASH exps -> dolist exps
        MAC e1 e2 -> dolist [e1, e2]
        HKDF e1 e2 e3 -> dolist [e1, e2, e3]
        PW_HASH exps -> dolist exps
        ENC e1 e2 -> dolist [e1, e2]
        DEC e1 e2 -> dolist [e1, e2]
        AEAD_ENC e1 e2 e3 -> dolist [e1, e2, e3]
        AEAD_DEC e1 e2 e3 -> dolist [e1, e2, e3]
        PKE_ENC e1 e2 -> dolist [e1, e2]
        PKE_DEC e1 e2 -> dolist [e1, e2]
        SIGN e1 e2 -> dolist [e1, e2]
        SIGNVERIF e1 e2 e3 -> dolist [e1, e2, e3]
        RINGSIGN e1 e2 e3 e4 -> dolist [e1, e2, e3, e4]
        RINGSIGNVERIF e1 e2 e3 e4 e5 -> dolist [e1, e2, e3, e4, e5]
        BLIND e1 e2 -> dolist [e1, e2]
        UNBLIND e1 e2 e3 -> dolist [e1, e2, e3]
        SHAMIR_SPLIT e1 -> dolist [e1]
        SHAMIR_JOIN e1 e2 -> dolist [e1, e2]

-- note that this can call f with the same constant
-- several times:
mapConstants :: a -> Constant -> (Constant -> a -> a) -> Map Constant Knowledge -> a
mapConstants acc c f m =
  case Map.lookup c m of
    Nothing -> acc
    Just vals ->
      case vals of
        Assignment exp ->
          foldConstantsInExpr (f c acc) exp (\c a -> mapConstants a c f m)
        Leaks -> f c acc
        Password -> f c acc
        Received _ -> f c acc
        Generates -> f c acc
        Public -> f c acc
        Private -> f c acc

addError :: ModelError -> State ModelState ()
addError err = modify (\st -> st { msErrors = err : msErrors st })

constantExistsOrError :: Constant -> State ModelState ()
constantExistsOrError const = do
  seen <- getConstant const ;
  case seen of
    Just _ -> return ()
    Nothing -> addError (MissingConstant const "TODO")
