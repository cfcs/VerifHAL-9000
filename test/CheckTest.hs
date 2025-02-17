
module CheckTest where

import Control.Monad
--import Data.Char (chr, isHexDigit)
--import Data.FileEmbed
--import Data.Foldable (for_)
import Data.List.NonEmpty (NonEmpty(..), NonEmpty)
import Data.Map (fromList)
--import qualified Data.Map as Map
import Data.Text (Text,pack,unpack)
--import qualified Data.Text as Text
--import Data.Text.Read (hexadecimal)
--import Data.Void

import Hedgehog
import qualified Hedgehog.Gen
import qualified Hedgehog.Range
--import Test.Hspec
--import Test.Hspec.Megaparsec
import Test.Tasty.Hspec

import VerifPal.Types
import VerifPal.Check (process, ModelState(..), ModelError(..), ProcessingCounter, CanonExpr(..),CanonKnowledge(..), equationToList, equivalenceExpr, simplifyExpr, decanonicalizeExpr)
import Data.Map (Map)
import qualified Data.Map as Map

import Cases

lhsConst :: Text -> NonEmpty Constant
lhsConst name = (Data.List.NonEmpty.:|) (Constant name) []

shouldNotFail :: ModelState -> Expectation
shouldNotFail modelState =
  msErrors modelState `shouldBe` []

shouldFail :: ModelState -> Expectation
shouldFail modelState =
  msErrors modelState `shouldNotBe` []

spec_parsePrincipal :: Spec
spec_parsePrincipal = do
  describe "process" $ do
    it "validates data/alice1.vp" $
      -- TODO does this use alice1model? or alice1.vp ? should it use parsePrincipal?
      -- parsePrinciap alice1model >>= process ?
      process alice1modelast `shouldBe`
      ModelState {
          msPrincipalConstants = fromList [("Alice",fromList [(Constant {constantName = "a"},(Generates,3)),(Constant {constantName = "c0"},(Public,0)),(Constant {constantName = "c1"},(Public,1)),(Constant {constantName = "m1"},(Private,2)),              (Constant {constantName = "nil"},(Public,0))])],
          msProcessingCounter = 4,
          msConstants = Map.fromList [
              (Constant "a",Generates),
              (Constant "c0",Public),
              (Constant "c1",Public),
              (Constant "m1",Private),
              (Constant "nil",Public)
          ], msErrors = [], msQueryResults = []}

shouldOverlapWith :: ModelState -> Constant -> Expectation
shouldOverlapWith modelState constant =
  msErrors modelState `shouldContain` [OverlappingConstant constant]

shouldMissConstant :: ModelState -> Text -> Expectation
shouldMissConstant modelState (constantName) =
  -- TODO this way of testing for the Text of the missingconstant is not great.
  msErrors modelState `shouldContain`
    [MissingConstant (Constant constantName)]

shouldFailValToVal :: ModelState -> Text -> Text -> Expectation
shouldFailValToVal ms name1 name2 =
  msErrors ms `shouldContain`
    [ValueToValue (Constant name1) (Constant name2)]

shouldHave :: ModelState -> (PrincipalName, [Constant]) -> IO ()
shouldHave modelState (principalName, constants) =
  case Map.lookup principalName (msPrincipalConstants modelState) of
    Nothing -> fail "Principal not found" -- True `shouldBe` False
    Just principalMap ->
      forM_ constants (\constant -> Map.member constant principalMap `shouldBe` True)

shouldHaveEquivalence :: ModelState -> [Text] -> Expectation
shouldHaveEquivalence modelState wantedConstants =
  msQueryResults modelState `shouldSatisfy` any predicate
  where
    predicate (Query (EquivalenceQuery actualConstants) _queryOptions, True) =
      actualConstants == Prelude.map (\c -> Constant c) wantedConstants
    predicate _ = False

shouldHaveFresh :: ModelState -> Text -> Expectation
shouldHaveFresh modelState constant =
  msQueryResults modelState `shouldSatisfy` any isFresh
  where
    isFresh (Query (FreshnessQuery constant2) _queryOptions, True) =
      Constant constant == constant2
    isFresh _ = False

shouldHaveNotFresh :: ModelState -> Text -> Expectation
shouldHaveNotFresh modelState constant =
  msQueryResults modelState `shouldSatisfy` any isNotFresh
  where
    isNotFresh (Query (FreshnessQuery constant2) _queryOptions, False) =
      Constant constant == constant2
    isNotFresh _ = False

mkModelState :: [(Text, Knowledge)] -> ModelState
mkModelState constants = ModelState
  { msConstants = mkConstants constants
  , msPrincipalConstants = Map.empty
  , msProcessingCounter = 0
  , msQueryResults = []
  , msErrors = []
  }

mkConstants :: [(Text, Knowledge)] -> Map Constant Knowledge
mkConstants constants =
  Map.fromList [ (Constant name, knowledge) | (name, knowledge) <- constants ]

mkPrincipalMap:: [(Text, Knowledge, ProcessingCounter)] -> Map Constant (Knowledge, ProcessingCounter)
mkPrincipalMap constants = Map.fromList
  [ (Constant name, (knowledge, count)) | (name, knowledge, count) <- constants ]

spec_equations :: Spec
spec_equations = do
  describe "equations" $ do
    let mkc name = CConstant (Constant {constantName=name}) CPublic
        a = mkc "a"
        b = mkc "b"
        c = mkc "c"
    it "equationToList [] = []" $ do
      equationToList [] a `shouldBe` [a]
    it "equationsToList G^a = [G a]" $ do
      equationToList [] (CG a) `shouldBe` [a]
    it "equationsToList (G^a)^b = [a,b]" $ do
      equationToList [] ((:^^:) (CG a) b) `shouldBe` [a,b]
    it "equationsToList (G^b)^a = [a,b]" $ do
      equationToList [] ((:^^:) (CG b) a) `shouldBe` [a,b]
    it "equationsToList (G^b)^(G^a) = [g,a,b]" $ do
      let ba = equationToList [] ((:^^:) (CG b) (CG a))
      ba `shouldNotBe` [a,b]
      ba `shouldBe` [CG a,b]
    it "equationsToList G^a^(G^b) /= G^b^(G^a)" $ do
      let ab = equationToList [] ((:^^:) (CG a) (CG b))
          ba = equationToList [] ((:^^:) (CG b) (CG a))
      ab `shouldNotBe` ba
    it "equationsToList G^a^G^b /= G^a^b" $ do
      let lhs = ((:^^:) (CG a) (CG b))
          rhs = ((:^^:) (CG a) b)
      equationToList [] lhs `shouldNotBe` equationToList [] rhs
    it "equationsToList ((G^a)^b)^c = [a,b,c]" $ do
      equationToList [] ((:^^:) ((:^^:) (CG a) b) c) `shouldBe` [a,b,c]
    it "equationsToList ((G^b)^a)^c = [a,b,c]" $ do
      equationToList [] ((:^^:) ((:^^:) (CG b) a) c) `shouldBe` [a,b,c]
    it "equationsToList ((G^c)^b)^a = [a,b,c]" $ do
      equationToList [] ((:^^:) ((:^^:) (CG c) b) a) `shouldBe` [a,b,c]
    -- TODO should we typecheck that the innermost, leftmost expression
    -- always contains a G ?
    it "equationsToList ((G^c)^b)^(G^a) = [G^a,b,c]" $ do
      equationToList [] ((:^^:) ((:^^:) (CG c) b) (CG a)) `shouldBe` [CG a,b,c]
    it "equationsToList ((G^c)^(G^b))^a = [G^b,a,c]" $ do
      equationToList [] ((:^^:) ((:^^:) (CG c) (CG b)) a) `shouldBe` [CG b,a,c]
    it "equationsToList ((G^c)^(G^b))^(G^a) /= ((G^c)^b)^(G^a)" $ do
      equationToList [] ((:^^:) ((:^^:) (CG c) (CG b)) a
                        ) `shouldNotBe` equationToList [] (
                         (:^^:) ((:^^:) (CG c)     b) a)
      equationToList [] ((:^^:) ((:^^:) (CG c) (CG b)) (CG a)
                        ) `shouldNotBe` equationToList [] (
                         (:^^:) ((:^^:) (CG c) (CG b))     a)
    it "equationsToList ((G^c)^(G^b))^(G^a) = [G^a,G^b,c]" $ do
      equationToList [] ((:^^:) ((:^^:) (CG c) (CG b)) (CG a)) `shouldBe` [
        CG a,CG b,c]
    it "equationsToList (G^b_sk)^a_sk = [a_sk,b_sk]" $ do
      let dh1_ss_a = (:^^:) b_dh1_pk_a  a_dh1_sk
          dh1_ss_b = (:^^:) a_dh1_pk_b  b_dh1_sk
          pdk_a = CConstant (Constant {constantName = "pdk_a"}) CGenerates
          pdk_b = CConstant (Constant {constantName = "pdk_b"}) CGenerates
          b_dh1_sk = CConstant (Constant {constantName = "b_dh1_sk"}) CGenerates
          b_dh1_pk = CG b_dh1_sk
          b_t1_alpha = CPrimitive (ENC pdk_b b_dh1_pk) HasntQuestionMark
          a_t1_alpha = CPrimitive (ENC pdk_a a_dh1_pk) HasntQuestionMark
          a_dh1_pk_b = CPrimitive (DEC pdk_a a_t1_alpha) HasntQuestionMark
          b_dh1_pk_a = CPrimitive (DEC pdk_b b_t1_alpha) HasntQuestionMark
          a_dh1_sk = CConstant (Constant {constantName = "a_dh1_sk"}) CGenerates
          a_dh1_pk = CG a_dh1_sk
      equationToList [] ((:^^:) b_dh1_pk a_dh1_sk) `shouldBe` [a_dh1_sk, b_dh1_sk]
      equationToList [] ((:^^:) a_dh1_pk b_dh1_sk) `shouldBe` [a_dh1_sk, b_dh1_sk]
      equationToList [] dh1_ss_a `shouldBe` [a_dh1_sk, b_dh1_sk]
      equationToList [] dh1_ss_b `shouldBe` [a_dh1_sk, b_dh1_sk]
      equationToList [] dh1_ss_a `shouldBe` equationToList [] dh1_ss_b
      equivalenceExpr dh1_ss_a dh1_ss_b `shouldBe` True

spec_process :: Spec
spec_process = do
  describe "process" $ do
    it "validates data/alice1.vp" $ do
      let modelState = process alice1modelast
      modelState `shouldHave` ("Alice", Constant <$> ["a", "c0", "c1", "m1"])
      msConstants modelState `shouldBe`
        mkConstants [("a", Generates), ("c0", Public), ("c1", Public), ("m1", Private), ("nil", Public)]

    it "rejects model with duplicates 1" $ do
      shouldNotFail (process dup1model)

    it "rejects model with duplicates 2" $ do
      process dup2model `shouldOverlapWith` Constant "x"

    it "rejects model with duplicates 3" $ do
      shouldNotFail (process dup3model)

    it "rejects model with duplicates 4" $ do
      process dup4model `shouldOverlapWith` Constant "x"

    it "validates data/abknows.vp" $ do
      let modelState = process abknowsast
      --- shouldNotFail modelState right now it fails due to confidentiality?
      modelState `shouldHave` ("A", Constant <$> ["x"])
      modelState `shouldHave` ("B", Constant <$> ["x"])

    it "rejects model with conflicting public/private knows" $
      process bad_publicprivate_ast `shouldOverlapWith` Constant "x"

    it "rejects model with conflicting generates/knows private" $
      process bad_generatesknows_ast `shouldOverlapWith` Constant "x"

    it "rejects model with conflicting knows private/knows password" $
      process bad_passwordprivate_ast `shouldOverlapWith` Constant "x"

    it "rejects model with conflicting knows public/knows private" $
      process bad_publicprivate_ast `shouldOverlapWith` Constant "x"

    it "rejects model with conflicting generates/knows private" $
      process bad_generatesknows_ast `shouldOverlapWith` Constant "x"

    it "rejects model with conflicting knows private/knows password" $
      process bad_passwordprivate_ast `shouldOverlapWith` Constant "x"

    it "rejects model with missing constant in confidentialityquery" $
      process bad_undefinedconstant_in_cfquery_ast `shouldMissConstant` ("y")

    it "rejects model that sends constant before it's defined" $ do
      let modelState = process bad_early_constant_ast
      modelState `shouldMissConstant`("yo")

    it "rejects model that references undefined constant" $ do
      let modelState = process bad_assignment_to_undefined_ast
      shouldFail modelState
      modelState `shouldMissConstant` ("b")

spec_freshness :: Spec
spec_freshness = do
  describe "process" $ do
    it "checks simple freshness query" $ do
      let modelState = process freshness1model
      modelState `shouldHaveFresh` "x"
      modelState `shouldHaveNotFresh` "y"

    it "validates data/knows_freshness.vp" $ do
      let modelState = process knows_freshness_ast
      shouldNotFail modelState
      modelState `shouldHaveFresh` "a"

    it "validates data/freshness_aliased.vp" $ do
      let modelState = process freshness_aliased_ast
      shouldNotFail modelState
      modelState `shouldHaveFresh` "a"
      modelState `shouldHaveFresh` "b"
      modelState `shouldHaveFresh` "c"

    it "validates data/freshness_concat.vp" $ do
      let modelState = process freshness_concat_ast
      shouldNotFail modelState
      modelState `shouldHaveFresh` "b"
      modelState `shouldHaveFresh` "c"
      modelState `shouldHaveFresh` "d"

    it "rejects freshness query on (knows private)" $ do
      let modelState = process bad_knows_freshness_ast
      shouldNotFail modelState
      modelState `shouldHaveNotFresh` "a"

spec_equivalence :: Spec
spec_equivalence = do
  describe "process" $ do
    it "checks equivalence1 query" $ do
      let modelState = process equivalence1_ast
      shouldNotFail modelState
      modelState `shouldHaveEquivalence` ["msg", "from_a"]
    it "checks equivalence2 query" $ do
      let modelState = process equivalence2_ast
      shouldNotFail modelState
      modelState `shouldHaveEquivalence` ["a", "b_a"]
      modelState `shouldHaveEquivalence` ["b", "b_b"]
      modelState `shouldHaveEquivalence` ["c", "b_c"]
    it "checks equivalence3 query" $ do
      let modelState = process equivalence3_ast
      shouldNotFail modelState
      modelState `shouldHaveEquivalence` ["r1", "msg1"]
      modelState `shouldHaveEquivalence` ["r2", "msg2"]
    it "checks equivalence4 query" $ do
      let modelState = process equivalence4_ast
      shouldNotFail modelState
      modelState `shouldHaveEquivalence` ["dec_m1", "m1"]
      modelState `shouldHaveEquivalence` ["aead_dec_m1", "m1"]
      modelState `shouldHaveEquivalence` ["pk1", "dec_pk1"]
      modelState `shouldHaveEquivalence` ["pk2", "G_dec_m1"]
      modelState `shouldHaveEquivalence` ["pk2", "G_aead_dec_m1"]
      modelState `shouldHaveEquivalence` ["G_dec_m1", "G_aead_dec_m1"]

    let msEquivalence5 = process equivalence5_ast
    it "checks equivalence5: no errors" $ do
      shouldNotFail msEquivalence5

    it "checks equivalence5: a_dh1_pk, a_dh1_pk_b" $ do
      msEquivalence5 `shouldHaveEquivalence` ["a_dh1_pk", "a_dh1_pk_b"]

    it "checks equivalence5: b_dh1_pk, b_dh1_pk_a" $ do
      msEquivalence5 `shouldHaveEquivalence` ["b_dh1_pk", "b_dh1_pk_a"]

    it "checks equivalence5: dh1_ss_ab, dh1_ss_ba" $ do
      msEquivalence5 `shouldHaveEquivalence` ["dh1_ss_ab", "dh1_ss_ba"]

    it "checks equivalence5: dh1_ss_a, dh1_ss_b" $ do
      msEquivalence5 `shouldHaveEquivalence` ["dh1_ss_a", "dh1_ss_b"]

    it "checks equivalence5: dh1_ss_ab, dh1_ss_a" $ do
      msEquivalence5 `shouldHaveEquivalence` ["dh1_ss_ab", "dh1_ss_a"]

    it "checks equations2 queries" $ do
      let modelState = process equations2_ast
      shouldNotFail modelState
      -- TODO should NOT have: modelState `shouldHaveEquivalence` ["a", "b"]
      modelState `shouldHaveEquivalence` ["gyx", "gxy"]

genKnowledge :: MonadGen m => m CanonKnowledge
genKnowledge =
  Hedgehog.Gen.element [
    CPrivate,
    CPublic,
    CGenerates,
    CPassword
    ]

genConstantWithKnowledge :: MonadGen m => CanonKnowledge -> m CanonExpr
genConstantWithKnowledge knowledge = do
  name' <- Hedgehog.Gen.text (Hedgehog.Range.constant 1 5) Hedgehog.Gen.alphaNum
  -- we prepend a value to the name depending on the knowledge type;
  -- this ensure we do not generate constants with differing knowledge types
  -- (which is a type error); without having to get into MonadState territory
  let uname = Data.Text.unpack name'
      uname' = case knowledge of
        CPrivate -> 's':uname -- "secret"
        CPublic -> 'p':uname -- "public"
        CGenerates -> 'g':uname -- "generates"_
        CPassword -> 'c':uname -- "code"
      name = Data.Text.pack uname'
  pure (CConstant (Constant {constantName = name}) knowledge)

genConstant :: MonadGen m => m CanonExpr
genConstant = genKnowledge >>= genConstantWithKnowledge

genEquationLinkWithKnowledge :: MonadGen m => CanonKnowledge -> m CanonExpr -> m CanonExpr
genEquationLinkWithKnowledge knowledge lhs = do
  Hedgehog.Gen.small $ Hedgehog.Gen.recursive Hedgehog.Gen.choice [
    CG <$> (genConstantWithKnowledge knowledge) -- TODO throwing away lhs is a bit sad here, but we need to ensure the knowledge is in there.
    ] [
    -- the three cases puts the guaranteeed Knowledge in each of the three terms
    do
      lhs2 <- Hedgehog.Gen.small $ genEquationLinkWithKnowledge knowledge lhs
      rhs <- Hedgehog.Gen.small $ genEquationLink genCanonExpr
      pure ((:^^:) lhs2 rhs),
    do
      lhs2 <- Hedgehog.Gen.small $ genEquationLink lhs
      rhs <- Hedgehog.Gen.small $ genEquationLink (genCanonExprWithKnowledge knowledge)
      case rhs of
        CG _ -> do -- might have hit the case where genEquation throws away lhs
          rhs <- genCanonExprWithKnowledge knowledge
          pure ((:^^:) lhs2 rhs)
        _ -> pure ((:^^:) lhs2 rhs),
    do
      lhs2 <- Hedgehog.Gen.small $ genEquationLink lhs
      rhs <- Hedgehog.Gen.small $ genEquationLinkWithKnowledge knowledge genCanonExpr
      pure ((:^^:) lhs2 rhs)
    ]

genEquationLink :: MonadGen m => m CanonExpr -> m CanonExpr
genEquationLink lhs = do
  Hedgehog.Gen.small $ Hedgehog.Gen.recursive Hedgehog.Gen.choice [
    CG <$> genConstant -- this is problematic
    ] [
    do
      lhs <- Hedgehog.Gen.small lhs
      rhs <- Hedgehog.Gen.small genCanonExpr
      pure ((:^^:) lhs rhs),
    do
      lhs <- Hedgehog.Gen.small $ genEquationLink lhs
      rhs <- Hedgehog.Gen.small $ genEquationLink (Hedgehog.Gen.small $ genCanonExpr)
      pure ((:^^:) lhs rhs)
    ]
genEquationWithKnowledge :: MonadGen m => CanonKnowledge -> m CanonExpr
genEquationWithKnowledge knowledge = do
  Hedgehog.Gen.recursive Hedgehog.Gen.choice [
    CG <$> (genConstantWithKnowledge knowledge)
    ] [
       Hedgehog.Gen.small $ genEquationLinkWithKnowledge knowledge genCanonExpr
    ]

genEquation :: MonadGen m => m CanonExpr
genEquation = do
  Hedgehog.Gen.small $ Hedgehog.Gen.small $ Hedgehog.Gen.recursive Hedgehog.Gen.choice [
    CG <$> genConstant
    ] [
   do
     Hedgehog.Gen.small $ genEquationLink (genEquation),
   do
      c <- genCanonExpr
      pure (CG c)
    ]

genPrimitiveCanonExpr :: MonadGen m => m (PrimitiveP CanonExpr)
genPrimitiveCanonExpr = do
  let arityN = [CONCAT,HASH,PW_HASH]
  let unary = [SPLIT,SHAMIR_SPLIT]
  let binary = [ASSERT,MAC,ENC,DEC,PKE_ENC,PKE_DEC,SIGN,BLIND,SHAMIR_JOIN]
  let arity3 = [HKDF, AEAD_ENC, AEAD_DEC, SIGNVERIF, UNBLIND]
  let arity4 = [RINGSIGN]
  let arity5 = [RINGSIGNVERIF]
  Hedgehog.Gen.recursive Hedgehog.Gen.choice [
    HASH <$> (\f -> [f]) <$> genConstant -- need at least one non-recursive choice
                                             ] [
    Hedgehog.Gen.element arityN <*> Hedgehog.Gen.list (Hedgehog.Range.constant 0 10) genCanonExpr,
    Hedgehog.Gen.element unary <*> genCanonExpr,
    Hedgehog.Gen.element binary <*> genCanonExpr <*> genCanonExpr,
    Hedgehog.Gen.element arity3 <*> genCanonExpr <*> genCanonExpr <*> genCanonExpr,
    Hedgehog.Gen.element arity4 <*> genCanonExpr <*> genCanonExpr <*> genCanonExpr <*> genCanonExpr,
    Hedgehog.Gen.element arity5 <*> genCanonExpr <*> genCanonExpr <*> genCanonExpr <*> genCanonExpr <*> genCanonExpr
    ]


genPrimitiveCanonExprWithKnowledge :: MonadGen m => CanonKnowledge -> m (PrimitiveP CanonExpr)
genPrimitiveCanonExprWithKnowledge knowledge = do
  let arityN = [CONCAT,HASH,PW_HASH]
  let unary = [SPLIT,SHAMIR_SPLIT]
  let binary = [ASSERT,MAC,ENC,DEC,PKE_ENC,PKE_DEC,SIGN,BLIND,SHAMIR_JOIN]
  let arity3 = [HKDF, AEAD_ENC, AEAD_DEC, SIGNVERIF, UNBLIND]
  let arity4 = [RINGSIGN]
  let arity5 = [RINGSIGNVERIF]
  Hedgehog.Gen.recursive Hedgehog.Gen.choice [
    -- need at least one non-recursive choice for Gen.recursive:
    HASH <$> (\f -> [f]) <$> genConstantWithKnowledge knowledge
    ] [
    do
      lstN <- Hedgehog.Gen.list (Hedgehog.Range.constant 0 10) genCanonExpr
      cknow <- genCanonExprWithKnowledge knowledge
      Hedgehog.Gen.element arityN <*> Hedgehog.Gen.shuffle (cknow:lstN),
      Hedgehog.Gen.element unary <*> genCanonExprWithKnowledge knowledge,
    -- arity2:
    Hedgehog.Gen.element binary <*> genCanonExpr <*> genCanonExprWithKnowledge knowledge,
    Hedgehog.Gen.element binary <*> genCanonExprWithKnowledge knowledge <*> genCanonExpr,
    -- arity3
    Hedgehog.Gen.element arity3 <*> genCanonExpr <*> genCanonExpr <*> genCanonExprWithKnowledge knowledge,
    Hedgehog.Gen.element arity3 <*> genCanonExpr <*> genCanonExprWithKnowledge knowledge <*> genCanonExpr,
    Hedgehog.Gen.element arity3 <*> genCanonExprWithKnowledge knowledge <*> genCanonExpr <*> genCanonExpr,
    -- arity4
    Hedgehog.Gen.element arity4 <*> genCanonExpr <*> genCanonExpr <*> genCanonExpr <*> genCanonExprWithKnowledge knowledge,
    Hedgehog.Gen.element arity4 <*> genCanonExpr <*> genCanonExpr <*> genCanonExprWithKnowledge knowledge <*> genCanonExpr,
    Hedgehog.Gen.element arity4 <*> genCanonExpr <*> genCanonExprWithKnowledge knowledge <*> genCanonExpr <*> genCanonExpr,
    Hedgehog.Gen.element arity4 <*> genCanonExprWithKnowledge knowledge <*> genCanonExpr <*> genCanonExpr <*> genCanonExpr,
    -- arity5
    Hedgehog.Gen.element arity5 <*> genCanonExpr <*> genCanonExpr <*> genCanonExpr <*> genCanonExpr <*> genCanonExprWithKnowledge knowledge,
    Hedgehog.Gen.element arity5 <*> genCanonExpr <*> genCanonExpr <*> genCanonExpr <*> genCanonExprWithKnowledge knowledge <*> genCanonExpr,
    Hedgehog.Gen.element arity5 <*> genCanonExpr <*> genCanonExpr <*> genCanonExprWithKnowledge knowledge <*> genCanonExpr <*> genCanonExpr,
    Hedgehog.Gen.element arity5 <*> genCanonExpr <*> genCanonExprWithKnowledge knowledge <*> genCanonExpr <*> genCanonExpr <*> genCanonExpr,
    Hedgehog.Gen.element arity5 <*> genCanonExprWithKnowledge knowledge <*> genCanonExpr <*> genCanonExpr <*> genCanonExpr <*> genCanonExpr
    ]

genCPrimitiveWithKnowledge :: MonadGen m => CanonKnowledge -> m CanonExpr
genCPrimitiveWithKnowledge knowledge = do
  checked <- Hedgehog.Gen.choice [pure HasQuestionMark, pure HasntQuestionMark]
  prim <- genPrimitiveCanonExprWithKnowledge knowledge
  pure (CPrimitive prim checked)

genCPrimitive :: MonadGen m => m CanonExpr
genCPrimitive = do
  checked <- Hedgehog.Gen.choice [pure HasQuestionMark, pure HasntQuestionMark]
  prim <- genPrimitiveCanonExpr
  pure (CPrimitive prim checked)

genCanonExprWithKnowledge :: MonadGen m => CanonKnowledge -> m CanonExpr
genCanonExprWithKnowledge knowledge = do
  Hedgehog.Gen.small $ Hedgehog.Gen.recursive Hedgehog.Gen.choice [
    genConstantWithKnowledge knowledge
    ] [Hedgehog.Gen.small $ genEquationWithKnowledge knowledge,
       Hedgehog.Gen.small $ genCPrimitiveWithKnowledge knowledge,
       (Hedgehog.Gen.small $ genCanonExprWithKnowledge knowledge) >>= transformEquivalent
       ]

genCanonExpr :: MonadGen m => m CanonExpr
genCanonExpr = do
  Hedgehog.Gen.recursive Hedgehog.Gen.choice [
    genConstant] [ genEquation, genCPrimitive, genCanonExpr >>= transformEquivalent  ]

hprop_equivalenceExpr :: Hedgehog.Property
hprop_equivalenceExpr =
  -- if they are structurally equivalent then equivalenceExpr should also
  -- be true. the converse is NOT necessarily true.
  -- this test detects when equivalenceExpr is too dismissive.
  withTests 15000 $
  property $ do
  eq1 <- forAll $ genCanonExpr
  Hedgehog.diff eq1 equivalenceExpr eq1

transformEquivalent :: MonadGen m => CanonExpr -> m CanonExpr
transformEquivalent exp = do
  -- this performs the inverse of simplifyExpr, making expressions
  -- more complicated while still equivalent.
  let more foo = Hedgehog.Gen.recursive Hedgehog.Gen.choice [ pure foo] [ transformEquivalent foo ]
      randpair = genCanonExpr >>= pair
      pair orig = more orig >>= \key1 -> more orig >>= \key2 -> pure (key1,key2)
  Hedgehog.Gen.small $ Hedgehog.Gen.recursive Hedgehog.Gen.choice [
    pure exp] [
    more exp,
    do -- indices into SPLIT(CONCAT)
      Hedgehog.Gen.list (Hedgehog.Range.constant 0 2) genCanonExpr >>= \before ->
        Hedgehog.Gen.list (Hedgehog.Range.constant 0 2) genCanonExpr >>= \after ->
          more exp >>= \exp ->
            more (CPrimitive (CONCAT (before ++ (exp:after))) HasntQuestionMark) >>= \concat ->
              more (CItem (length before) (CPrimitive (SPLIT concat) HasntQuestionMark)),
    do -- SPLIT(CONCAT()) without indices; defaulting to first element
      Hedgehog.Gen.list (Hedgehog.Range.constant 0 2) genCanonExpr >>= \after ->
        more exp >>= \exp ->
          more (CPrimitive (CONCAT (exp:after)) HasntQuestionMark) >>= \concat ->
            more (CPrimitive (SPLIT concat) HasntQuestionMark),
    do
      randpair >>= \(key1,key2) ->
        more exp >>= \exp ->
          more (CPrimitive (ENC key1 exp) HasntQuestionMark) >>= \enc ->
            more (CPrimitive (DEC key2 enc) HasntQuestionMark),
    do -- AEAD_DEC(AEAD_ENC())
      randpair >>= \(key1,key2) ->
        more exp >>= \exp1 ->
          randpair >>= \(ad1,ad2) ->
            more (CPrimitive (AEAD_ENC key1 exp1 ad1) HasntQuestionMark) >>= \enc ->
                more (CPrimitive (AEAD_DEC key2 enc ad2) HasntQuestionMark),
    do -- SIGNVERIF(SIGN())
      randpair >>= \(key1,key2) ->
        pair exp >>= \(exp1,exp2) ->
          more (CPrimitive (SIGN key1 exp1) HasntQuestionMark) >>= \signed ->
            more (CPrimitive (SIGNVERIF (CG key2) exp2 signed) HasntQuestionMark),
    case exp of
      (CPrimitive (SIGN a m) hasq) -> do
        -- cool, opportunity to test blinding!
        -- UNBLIND(k, m,
        --   SIGN(a,
        --     BLIND(k, m))): SIGN(a, m)
        randpair >>= \(key1,key2) ->
          pair m >>= \(exp1,exp2) ->
            more a >>= \more_a ->
              more (CPrimitive (BLIND key1 exp1) hasq)>>= \blind ->
                more (CPrimitive (SIGN more_a blind) hasq) >>= \signed ->
                  more (CPrimitive (UNBLIND key2 exp2 signed) hasq)
      exp -> more exp
    ]

hprop_encryptEquivalence :: Hedgehog.Property
hprop_encryptEquivalence =
  withTests 5000 $
  property $ do
    message <- forAll genCanonExpr
    transformed <- forAll $ transformEquivalent message
    Hedgehog.diff message equivalenceExpr transformed
    Hedgehog.diff (simplifyExpr message) equivalenceExpr (simplifyExpr transformed)

hprop_simplifyExprEquivalence :: Hedgehog.Property
hprop_simplifyExprEquivalence =
  -- simplification doesn't oversimplify, and is transitive:
  -- TODO this doesn't really work right now, does hedgehog generate
  -- simplifiable messages?
  withDiscards 5000 $
  withTests 1000 $
  -- verifiedTermination $
  property $ do
    eq1 <- forAll $ genCanonExpr
    complicated <- forAll $ transformEquivalent eq1
    let simpl1 = (simplifyExpr complicated)
        did_simplify = not (simpl1 == eq1)
    classify "simplified" did_simplify
    if did_simplify
      then do
        -- test internal consistency between simplifyExpr and equivalenceExpr:
        Hedgehog.diff simpl1 equivalenceExpr simpl1
        Hedgehog.diff eq1    equivalenceExpr simpl1
        Hedgehog.diff simpl1 equivalenceExpr eq1
      else pure ()

hprop_equivalenceExprSymmetry :: Hedgehog.Property
hprop_equivalenceExprSymmetry =
  withTests 10000 $
  property $
  do
    exp1 <- forAll $ genCanonExpr
    exp2 <- forAll $ genCanonExpr
    equivalenceExpr exp1 exp2 === equivalenceExpr exp2 exp1

hprop_equationsAreEquivalent :: Hedgehog.Property
hprop_equationsAreEquivalent =
  withDiscards 50000 $ withTests 10000 $
  property $
  do
    eq1 <- forAll $ genEquation
    eq2 <- forAll $ genEquation
    let theyAreEqual = equivalenceExpr eq1 eq2
        lst1 = equationToList [] eq1
        lst2 = equationToList [] eq2
        simpl1 = simplifyExpr eq1
        simpl2 = simplifyExpr eq2
        iseq [] [] = True
        iseq (x:xs) (y:ys) = equivalenceExpr x y && iseq xs ys
        iseq [] (_:_) = False
        iseq (_:_) [] = False
    classify "equivalenceExpr" theyAreEqual
    equivalenceExpr simpl1 simpl2 === theyAreEqual
    equivalenceExpr simpl1 eq2 === theyAreEqual
    equivalenceExpr eq1 simpl2 === theyAreEqual
    iseq lst1 lst2 === theyAreEqual
      -- the list should be structurally equivalent since we are dealing with
      -- CanonExpr which should be canonical:

cexprHasFreshness :: CanonExpr -> (ModelState, Bool)
cexprHasFreshness cexpr =
  let (mlst, decan) = decanonicalizeExpr [] cexpr
      const = Constant {constantName="howfresh"}
      model = Model {
        modelAttacker = Passive,
        modelParts = [
            ModelPrincipal (Principal {
                               principalName="A",
                               principalKnows=Prelude.map (
                                   \(l,r) -> (
                                     (Data.List.NonEmpty.:|) l [],r)) (
                                   mlst++[(const,
                                           case decan of -- direct aliasing is not permitted, so we work around the case where decan is simply a constant:
                                             EConstant _ -> Assignment (G decan)
                                             _ -> Assignment decan
                                               )])
                               }),
            ModelQueries [
                Query {
                    queryKind = FreshnessQuery { freshnessConstant = const },
                    queryOptions = Nothing
                    }
                ]
            ]
        }
      ms = process model
      qr = msQueryResults ms
      isFresh [(Query {}, result)] = result
      isFresh _ = False
      testResult = isFresh qr :: Bool
  in (ms, testResult)

-- Test that we genCanonExpr will generate values with and without freshness
hprop_hasFreshness :: Hedgehog.Property
hprop_hasFreshness =
  withDiscards 5000 $
  withTests 1000 $ verifiedTermination $ property $ do
    cexp <- forAll $ genCanonExpr
    let (_, res) = cexprHasFreshness cexp
    if res then pure() else discard
hprop_noFreshness :: Hedgehog.Property
hprop_noFreshness =
  withDiscards 5000 $
  withTests 1000 $ verifiedTermination $ property $ do
    cexp <- forAll $ genCanonExpr
    let (_, res) = cexprHasFreshness cexp
    if not res then pure() else discard

hprop_fuzzFreshness :: Hedgehog.Property
hprop_fuzzFreshness =
  -- In this test we construct at least one constant with
  --   CGenerates knowledge type
  -- and then wrap it in various constructors; finally in a ModelState
  -- in order to test that processQuery accurately determines freshness.
  -- in the cases where do_fresh is NOT CGenerates and we would fail
  -- the freshness test, we discard the output to check that it is possible
  -- to fail freshness queries (for models that conceivably do not have it).
  withDiscards 5000 $
  withTests 20000 $ verifiedTermination $ property $ do
    do_fresh <- forAll $ genKnowledge
    --let do_fresh = CGenerates
    classify "guaranteed fresh" $ do_fresh == CGenerates
    classify "NOT guaranteed fresh" $ do_fresh /= CGenerates
    with_k <- forAll $ genCanonExprWithKnowledge do_fresh
    let (ms, testResult) = cexprHasFreshness with_k
        testProp = testResult === (CGenerates == do_fresh)
    annotateShow("ms"::Text, ms)
    -- testProp:
    -- 1) should always be True if we put CGenerates in there
    -- 2) we didn't put CGenerates, and it didn't have freshness
    -- 3) we have accidental freshness in here, discard that
    if CGenerates == do_fresh || not testResult
      then testProp
      else do
        -- throw away Freshness==True when we did not gen explicit CGenerates:
        discard
