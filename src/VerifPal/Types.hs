{-# LANGUAGE GADTs #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
-- Based on: https://verifpal.com/res/pdf/manual.pdf


module VerifPal.Types where

import Data.Set()
import Data.List.NonEmpty(NonEmpty)
import Data.Map.Strict ()
import qualified Data.Map.Strict()
import Data.Text (Text)

data Model = Model
  { modelAttacker :: Attacker
  , modelParts :: [ModelPart]
  } deriving (Eq, Ord, Show)

data Attacker
  = Active
  | Passive
  deriving (Eq, Ord, Show)

data ModelPart where
  ModelPrincipal :: Principal -> ModelPart
  ModelMessage :: Message -> ModelPart
  ModelPhase :: Phase -> ModelPart
  ModelQueries :: [Query] -> ModelPart
  deriving (Eq, Ord, Show)

data Principal = Principal
  { principalName :: PrincipalName
  , principalKnows :: [(NonEmpty Constant, Knowledge)]
  } deriving (Eq, Ord, Show)

type PrincipalName = Text

data Message = Message
  { messageSender :: PrincipalName
  , messageReceiver :: PrincipalName
  , messageConstants :: [(Constant, Guarded)]
  } deriving (Eq, Ord, Show)

type Guarded = Bool

newtype Phase = Phase
  { phaseNumber :: Word
  } deriving (Eq, Ord, Show)

data Query = Query
  { queryKind :: QueryKind
  , queryOptions :: Maybe QueryOption
  } deriving (Eq, Ord, Show)

data QueryKind
  = ConfidentialityQuery { confidentialityConstant :: Constant }
  | AuthenticationQuery { authenticationMessage :: Message }
  | FreshnessQuery { freshnessConstant :: Constant }
  | UnlinkabilityQuery { unlinkabilityConstants :: [Constant] }
  | EquivalenceQuery { equivalenceConstants :: [Constant] }
  deriving (Eq, Ord, Show)

data QueryOption = QueryOption { queryOptionMessage :: Message }
  deriving (Eq, Ord, Show)

-- Fundamental types: Constants, primitives, equations

-- Constants:
--  * Immutable, global namespace, can't be assigned to one another.
--  * Constants can only be assigned to primitives or equations.
--
newtype Constant = Constant
  { constantName :: Text
  } deriving (Eq, Ord, Show)

mkConst :: Text -> Expr
mkConst = EConstant . Constant

data Knowledge
  = Private   -- ^ Known ahead by principal only
  | Public    -- ^ Known ahead by everyone
  | Generates -- ^ Generated by principal ("ephemeral")
  | Password  -- ^ Alternative to Private, allows the attacker to guess
  | Leaks     -- ^ existing constant leaked to attacker
  | Assignment Expr
  | Received Int -- ^ received in a message, e.g. Public  after message has been sent. The Int counts messages TODO is this Int still needed?
  deriving (Ord, Show, Eq)
-- Primitives:
--  * Decompose: Given ENC(k, m) and k, reveal m.
--  * Recompose: Given a, b, reveal x if a, b = SHAMIR_SPLIT(x)
--  * Rewrite: Given DEC(k, ENC(k, m)), rewrite this to m.
--  * Rebuild: Given SHAMIR_JOIN(a, b) where a, b = SHAMIR_SPLIT(x),
--             rewrite SHAMIR_JOIN(a, b) to x.

data Expr 
    -- Equations
  = G Expr                                -- G^...
  | (:^:) Constant Expr                   -- a^b
  | EConstant Constant                    -- a
  | EPrimitive Primitive CheckedPrimitive -- ...?
  | EItem Int Expr -- lhs assignments, basically. the Int is an indice
  deriving (Eq, Ord, Show)

type Primitive = PrimitiveP Expr
data PrimitiveP expr
    -- Core primitives
  = ASSERT expr expr  -- ASSERT(a, b): unused
  | CONCAT [expr]     -- CONCAT(a, b): c
  | SPLIT expr        -- SPLIT(...CONCAT(a, b)...): a, b

    -- Hashing primitives
  | HASH [expr]      -- HASH(a, ..., e): x
  | MAC expr expr                -- MAC(key, message): hash
  | HKDF expr expr expr  -- HKDF(salt, ikm, info): a, ..., e
  | PW_HASH [expr]   -- PW_HASH(a, ..., e): x

    -- Encryption primitives
  | ENC expr expr  -- ENC(key, plaintext): ciphertext
  | DEC expr expr  -- DEC(key, ENC(key, plaintext)): plaintext
  | AEAD_ENC expr expr expr  -- AEAD_ENC(key, plaintext, ad): ciphertext
  | AEAD_DEC expr expr expr  -- AEAD_DEC(key, AEAD_ENC(key, plaintext, ad), ad): plaintext
  | PKE_ENC expr expr   -- PKE_ENC(G^key, plaintext): ciphertext
  | PKE_DEC expr expr   -- PKE_DEC(key, PKE_ENC(G^key, plaintext)): plaintext

    -- Signature primitives
  | SIGN expr expr          -- SIGN(key, message): signature
  | SIGNVERIF expr expr expr   -- SIGNVERIF(G^key, message, SIGN(key, message)): message
  | RINGSIGN expr expr expr expr  -- RINGSIGN(key_a, G^key_b, G^key_c, message): signature
  | RINGSIGNVERIF expr expr expr expr expr  -- RINGSIGNVERIF(G^a, G^b, G^c, m, RINGSIGN(a, G^b, G^c, m)): m
  | BLIND expr expr  -- BLIND(k, m): m
  | UNBLIND expr expr expr  -- UNBLIND(k, m, SIGN(a, BLIND(k, m))): SIGN(a, m)

    -- Secret sharing primitives
  | SHAMIR_SPLIT expr  -- SHAMIR_SPLIT(k): s1, s2, s3
  | SHAMIR_JOIN expr expr -- SHAMIR_JOIN(sa, sb): k
  deriving (Eq, Ord, Show)

-- Checked Primitive:  if you add a question mark (?) after one of these
-- primitives, then model execution will abort should AEAD_DEC fail
-- authenticated decryption, or should ASSERT fail to find its two provided
-- inputs equal, or should SIGNVERIF fail to verify the signature against the
-- provided message and public key.
--
-- TODO: Propagate this to the assigned
data CheckedPrimitive
  = HasQuestionMark
  | HasntQuestionMark
  deriving (Eq, Ord, Show)
