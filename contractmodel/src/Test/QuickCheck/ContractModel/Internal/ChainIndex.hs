module Test.QuickCheck.ContractModel.Internal.ChainIndex where

import Control.Monad.State

import Data.Ord
import Data.List
import Data.Map (Map)
import Data.Map qualified as Map

import Cardano.Api
import Cardano.Api.Shelley
import Cardano.Ledger.Shelley.TxBody (WitVKey (..))
import Cardano.Ledger.Keys (hashKey, coerceKeyRole)

import Test.QuickCheck.ContractModel.Internal.Common
import Test.QuickCheck.ContractModel.Internal.Utils

data ChainState = ChainState
  { slot :: SlotNo
  , utxo :: UTxO Era
  }

data TxInState = TxInState
  { tx         :: Tx Era
  , chainState :: ChainState
  , accepted   :: Bool
  }

-- TODO: before and after here can be completely ignored! We can't implement that right now
-- because we have a spiral dependency with plutus apps but eventually we will be able to!
data ChainIndex = ChainIndex
  { before       :: ChainState
  , after        :: ChainState
  , transactions :: [TxInState]
  , networkId    :: NetworkId
  }

instance Semigroup ChainIndex where
  ci <> ci' = ChainIndex { before       = error "this code should be dead"
                         , after        = error "this code should be dead"
                         , transactions = sortBy (comparing (slot . chainState))
                                        $ transactions ci ++ transactions ci'
                         , networkId    = networkId ci
                         }

class HasChainIndex m where
  getChainIndex :: m ChainIndex

allMinAda :: ChainIndex
          -> ProtocolParameters
          -> [Lovelace]
allMinAda ci params =
  [ selectLovelace v
  | TxInState{..} <- transactions ci
  , txOut <- getTxOuts tx
  , Right v <- [calculateMinimumUTxO era txOut params]
  , accepted
  ]

type FeeCalculation = NetworkId -> TxInState -> Map (AddressInEra Era) Value

signerPaysFees :: FeeCalculation
signerPaysFees nid TxInState{tx = tx, accepted = accepted}
  | not accepted = error "TODO: signerPaysFees rejected tx"
  | Tx (TxBody (txFee -> TxFeeExplicit _ lov)) [wit] <- tx = Map.singleton (shelleyAddressInEra $ mkAddrFromWitness nid wit) (lovelaceToValue lov)
  | otherwise = mempty

-- TODO: is this really safe?? also - why is this so complicated??
mkAddrFromWitness :: NetworkId -> KeyWitness Era -> Address ShelleyAddr
mkAddrFromWitness nid wit = makeShelleyAddress nid
                                               (keyHashObj wit)
                                               NoStakeAddress
  where keyHashObj :: KeyWitness Era -> PaymentCredential
        keyHashObj (ShelleyKeyWitness _ (WitVKey wit _)) =
            PaymentCredentialByKey
          . PaymentKeyHash
          . hashKey
          . coerceKeyRole   -- TODO: is this really safe?!?!?!
          $ wit
        keyHashObj ShelleyBootstrapWitness{} = error "keyHashObj: ShelleyBootstrapWitness{}"

-- TODO: what about failing transactions?
getBalanceChangesDiscountingFees :: ChainIndex
                                 -> FeeCalculation
                                 -> Map (AddressInEra Era) Value
getBalanceChangesDiscountingFees ChainIndex{..} computeFees =
  foldr (Map.unionWith (<>)) mempty $  map txBalanceChanges transactions
                                    ++ map (computeFees networkId) transactions

txBalanceChanges :: TxInState
                 -> Map (AddressInEra Era) Value
txBalanceChanges (TxInState tx ChainState{..} accepted)
  | accepted = Map.unionsWith (<>) $ [ Map.singleton a (txOutValueToValue v)
                                     | TxOut a v _ _ <- getTxOuts tx
                                     ] ++
                                     [ Map.singleton a (negateValue $ txOutValueToValue v)
                                     | TxOut a v _ _ <- getTxInputs tx utxo
                                     ]
  | otherwise = error "TODO txBalanceChanges when removing collateral"

instance (Monad m, HasChainIndex m) => HasChainIndex (StateT s m) where
  getChainIndex = lift $ getChainIndex
