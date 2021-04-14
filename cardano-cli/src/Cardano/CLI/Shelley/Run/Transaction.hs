{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}

{-# OPTIONS_GHC -Wno-incomplete-uni-patterns #-}

module Cardano.CLI.Shelley.Run.Transaction
  ( ShelleyTxCmdError
  , renderShelleyTxCmdError
  , runTransactionCmd
  ) where

import           Cardano.Prelude hiding (All, Any)
import           Prelude (String)

import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.Text as Text
import           Data.Type.Equality (TestEquality (..))

import           Control.Monad.Trans.Except.Extra (firstExceptT, handleIOExceptT, hoistEither,
                   hoistMaybe, left, newExceptT)

import           Cardano.Api
import           Cardano.Api.Byron hiding (SomeByronSigningKey (..))
import           Cardano.Api.Shelley
import           Ouroboros.Consensus.Shelley.Eras (StandardAllegra, StandardMary, StandardShelley)

--TODO: do this nicely via the API too:
import qualified Cardano.Binary as CBOR

--TODO: following import needed for orphan Eq Script instance
import           Cardano.Ledger.ShelleyMA.TxBody ()
import           Shelley.Spec.Ledger.Scripts ()

import           Ouroboros.Consensus.Byron.Ledger (ByronBlock)
import           Ouroboros.Consensus.Cardano.Block (EraMismatch (..))
import           Ouroboros.Consensus.Ledger.SupportsMempool (ApplyTxErr)
import           Ouroboros.Consensus.Shelley.Ledger (ShelleyBlock)
import qualified Ouroboros.Network.Protocol.LocalTxSubmission.Client as Net.Tx

import           Cardano.CLI.Environment (EnvSocketError, readEnvSocketPath, renderEnvSocketError)
import           Cardano.CLI.Run.Friendly (friendlyTxBodyBS)
import           Cardano.CLI.Shelley.Key (InputDecodeError, readSigningKeyFileAnyOf)
import           Cardano.CLI.Shelley.Parsers
import           Cardano.CLI.Shelley.Run.Genesis (ShelleyGenesisCmdError (..), readShelleyGenesis,
                   renderShelleyGenesisCmdError)
import           Cardano.CLI.Types

data ShelleyTxCmdError
  = ShelleyTxCmdAesonDecodeProtocolParamsError !FilePath !Text
  | ShelleyTxCmdReadFileError !(FileError ())
  | ShelleyTxCmdReadJsonFileError (FileError JsonDecodeError)
  | ShelleyTxCmdReadTextViewFileError !(FileError TextEnvelopeError)
  | ShelleyTxCmdReadWitnessSigningDataError !ReadWitnessSigningDataError
  | ShelleyTxCmdWriteFileError !(FileError ())
  | ShelleyTxCmdEraConsensusModeMismatch
      !FilePath
      !AnyConsensusMode
      !AnyCardanoEra
      -- ^ Era
  | ShelleyTxCmdMetadataJsonParseError !FilePath !String
  | ShelleyTxCmdMetadataConversionError !FilePath !TxMetadataJsonError
  | ShelleyTxCmdMetaValidationError !FilePath ![(Word64, TxMetadataRangeError)]
  | ShelleyTxCmdMetaDecodeError !FilePath !CBOR.DecoderError
  | ShelleyTxCmdBootstrapWitnessError !ShelleyBootstrapWitnessError
  | ShelleyTxCmdSocketEnvError !EnvSocketError
  | ShelleyTxCmdTxSubmitError !Text
  | ShelleyTxCmdTxSubmitErrorByron !(ApplyTxErr ByronBlock)
  | ShelleyTxCmdTxSubmitErrorShelley !(ApplyTxErr (ShelleyBlock StandardShelley))
  | ShelleyTxCmdTxSubmitErrorAllegra !(ApplyTxErr (ShelleyBlock StandardAllegra))
  | ShelleyTxCmdTxSubmitErrorMary !(ApplyTxErr (ShelleyBlock StandardMary))
  | ShelleyTxCmdTxSubmitErrorEraMismatch !EraMismatch
  | ShelleyTxCmdTxFeatureMismatch AnyCardanoEra TxFeature
  | ShelleyTxCmdTxBodyError SomeTxBodyError
  | ShelleyTxCmdNotImplemented Text
  | ShelleyTxCmdWitnessEraMismatch AnyCardanoEra AnyCardanoEra WitnessFile
  | ShelleyTxCmdScriptLanguageNotSupportedInEra AnyScriptLanguage AnyCardanoEra
  | ShelleyTxCmdGenesisCmdError !ShelleyGenesisCmdError
  deriving Show

data SomeTxBodyError where
     SomeTxBodyError :: TxBodyError era -> SomeTxBodyError

deriving instance Show SomeTxBodyError


renderShelleyTxCmdError :: ShelleyTxCmdError -> Text
renderShelleyTxCmdError err =
  case err of
    ShelleyTxCmdReadFileError fileErr -> Text.pack (displayError fileErr)
    ShelleyTxCmdReadTextViewFileError fileErr -> Text.pack (displayError fileErr)
    ShelleyTxCmdReadJsonFileError  fileErr -> Text.pack (displayError fileErr)
    ShelleyTxCmdReadWitnessSigningDataError witSignDataErr ->
      renderReadWitnessSigningDataError witSignDataErr
    ShelleyTxCmdWriteFileError fileErr -> Text.pack (displayError fileErr)
    ShelleyTxCmdMetadataJsonParseError fp jsonErr ->
       "Invalid JSON format in file: " <> show fp
                <> "\nJSON parse error: " <> Text.pack jsonErr
    ShelleyTxCmdMetadataConversionError fp metadataErr ->
       "Error reading metadata at: " <> show fp
                             <> "\n" <> Text.pack (displayError metadataErr)
    ShelleyTxCmdMetaDecodeError fp metadataErr ->
       "Error decoding CBOR metadata at: " <> show fp
                             <> " Error: " <> show metadataErr
    ShelleyTxCmdMetaValidationError fp errs ->
      "Error validating transaction metadata at: " <> show fp <> "\n" <>
      Text.intercalate "\n"
        [ "key " <> show k <> ":" <> Text.pack (displayError valErr)
        | (k, valErr) <- errs ]
    ShelleyTxCmdSocketEnvError envSockErr -> renderEnvSocketError envSockErr
    ShelleyTxCmdAesonDecodeProtocolParamsError fp decErr ->
      "Error while decoding the protocol parameters at: " <> show fp
                                            <> " Error: " <> show decErr
    ShelleyTxCmdTxSubmitError res -> "Error while submitting tx: " <> res
    ShelleyTxCmdTxSubmitErrorByron res ->
      "Error while submitting tx: " <> Text.pack (show res)
    ShelleyTxCmdTxSubmitErrorShelley res ->
      "Error while submitting tx: " <> Text.pack (show res)
    ShelleyTxCmdTxSubmitErrorAllegra res ->
      "Error while submitting tx: " <> Text.pack (show res)
    ShelleyTxCmdTxSubmitErrorMary res ->
      "Error while submitting tx: " <> Text.pack (show res)
    ShelleyTxCmdTxSubmitErrorEraMismatch EraMismatch{ledgerEraName, otherEraName} ->
      "The era of the node and the tx do not match. " <>
      "The node is running in the " <> ledgerEraName <>
      " era, but the transaction is for the " <> otherEraName <> " era."
    ShelleyTxCmdBootstrapWitnessError sbwErr ->
      renderShelleyBootstrapWitnessError sbwErr

    ShelleyTxCmdTxFeatureMismatch era TxFeatureImplicitFees ->
      "An explicit transaction fee must be specified for " <>
      renderEra era <> " era transactions."

    ShelleyTxCmdTxFeatureMismatch (AnyCardanoEra ShelleyEra)
                                  TxFeatureValidityNoUpperBound ->
      "A TTL must be specified for Shelley era transactions."

    ShelleyTxCmdTxFeatureMismatch era feature ->
      renderFeature feature <> " cannot be used for " <> renderEra era <>
      " era transactions."

    ShelleyTxCmdTxBodyError (SomeTxBodyError err') ->
      "Transaction validaton error: " <> Text.pack (displayError err')

    ShelleyTxCmdNotImplemented msg ->
      "Feature not yet implemented: " <> msg

    ShelleyTxCmdWitnessEraMismatch era era' (WitnessFile file) ->
      "The era of a witness does not match the era of the transaction. " <>
      "The transaction is for the " <> renderEra era <> " era, but the " <>
      "witness in " <> show file <> " is for the " <> renderEra era' <> " era."

    ShelleyTxCmdScriptLanguageNotSupportedInEra (AnyScriptLanguage lang) era ->
      "The script language " <> show lang <> " is not supported in the " <>
      renderEra era <> " era."
    ShelleyTxCmdEraConsensusModeMismatch fp mode era ->
       "Submitting " <> renderEra era <> " era transaction (" <> show fp <>
       ") is not supported in the " <> renderMode mode <> " consensus mode."
    ShelleyTxCmdGenesisCmdError e -> renderShelleyGenesisCmdError e

renderEra :: AnyCardanoEra -> Text
renderEra (AnyCardanoEra ByronEra)   = "Byron"
renderEra (AnyCardanoEra ShelleyEra) = "Shelley"
renderEra (AnyCardanoEra AllegraEra) = "Allegra"
renderEra (AnyCardanoEra MaryEra)    = "Mary"
renderEra (AnyCardanoEra AlonzoEra)  = "Alonzo"

renderMode :: AnyConsensusMode -> Text
renderMode (AnyConsensusMode ByronMode) = "ByronMode"
renderMode (AnyConsensusMode ShelleyMode) = "ShelleyMode"
renderMode (AnyConsensusMode CardanoMode) = "CardanoMode"

renderFeature :: TxFeature -> Text
renderFeature TxFeatureShelleyAddresses     = "Shelley addresses"
renderFeature TxFeatureExplicitFees         = "Explicit fees"
renderFeature TxFeatureImplicitFees         = "Implicit fees"
renderFeature TxFeatureValidityLowerBound   = "A validity lower bound"
renderFeature TxFeatureValidityUpperBound   = "A validity upper bound"
renderFeature TxFeatureValidityNoUpperBound = "An absent validity upper bound"
renderFeature TxFeatureTxMetadata           = "Transaction metadata"
renderFeature TxFeatureAuxScripts           = "Auxiliary scripts"
renderFeature TxFeatureWithdrawals          = "Reward account withdrawals"
renderFeature TxFeatureCertificates         = "Certificates"
renderFeature TxFeatureMintValue            = "Asset minting"
renderFeature TxFeatureMultiAssetOutputs    = "Multi-Asset outputs"
renderFeature TxFeatureScriptWitnesses      = "Script witnesses"
renderFeature TxFeatureShelleyKeys          = "Shelley keys"
renderFeature TxFeatureWitnessPPData        = panic "TODO"

runTransactionCmd :: TransactionCmd -> ExceptT ShelleyTxCmdError IO ()
runTransactionCmd cmd =
  case cmd of
    TxBuildRaw era txins txouts mValue mLowBound mUpperBound
               fee certs wdrls metadataSchema scriptFiles
               _mProtocolParams metadataFiles mUpProp out ->
      runTxBuildRaw era txins txouts mLowBound mUpperBound
                    fee mValue certs wdrls metadataSchema
                    scriptFiles metadataFiles mUpProp out
    TxSign txinfile skfiles network txoutfile ->
      runTxSign txinfile skfiles network txoutfile
    TxSubmit anyConensusModeParams network txFp ->
      runTxSubmit anyConensusModeParams network txFp
    TxCalculateMinFee txbody mnw pGenesisOrParamsFile nInputs nOutputs
                      nShelleyKeyWitnesses nByronKeyWitnesses ->
      runTxCalculateMinFee txbody mnw pGenesisOrParamsFile nInputs nOutputs
                           nShelleyKeyWitnesses nByronKeyWitnesses
    TxGetTxId txinfile -> runTxGetTxId txinfile
    TxView txinfile -> runTxView txinfile
    TxMintedPolicyId sFile -> runTxCreatePolicyId sFile
    TxCreateWitness txBodyfile witSignData mbNw outFile ->
      runTxCreateWitness txBodyfile witSignData mbNw outFile
    TxAssembleTxBodyWitness txBodyFile witnessFile outFile ->
      runTxSignWitness txBodyFile witnessFile outFile

-- ----------------------------------------------------------------------------
-- Building transactions
--

runTxBuildRaw
  :: AnyCardanoEra
  -> [TxIn]
  -> [TxOutAnyEra]
  -> Maybe SlotNo
  -- ^ Tx lower bound
  -> Maybe SlotNo
  -- ^ Tx upper bound
  -> Maybe Lovelace
  -- ^ Tx fee
  -> Maybe Value
  -- ^ Multi-Asset value
  -> [CertificateFile]
  -> [(StakeAddress, Lovelace)]
  -> TxMetadataJsonSchema
  -> [ScriptFile]
  -> [MetadataFile]
  -> Maybe UpdateProposalFile
  -> TxBodyFile
  -> ExceptT ShelleyTxCmdError IO ()
runTxBuildRaw (AnyCardanoEra era) txins txouts mLowerBound
              mUpperBound mFee mValue
              certFiles withdrawals
              metadataSchema scriptFiles
              metadataFiles mUpdatePropFile
              (TxBodyFile fpath) = do

    txBodyContent <-
      TxBodyContent
        <$> validateTxIns  era txins
        <*> validateTxOuts era txouts
        <*> validateTxFee  era mFee
        <*> ((,) <$> validateTxValidityLowerBound era mLowerBound
                 <*> validateTxValidityUpperBound era mUpperBound)
        <*> validateTxMetadataInEra  era metadataSchema metadataFiles
        <*> validateTxAuxScripts     era scriptFiles
        <*> validateTxWithdrawals    era withdrawals
        <*> validateTxCertificates   era certFiles
        <*> validateTxUpdateProposal era mUpdatePropFile
        <*> validateTxMintValue      era mValue
        <*> panic "txExecutionUnits"
        <*> panic "txWitnessPPData" -- Should be a hash!
    txBody <-
      firstExceptT (ShelleyTxCmdTxBodyError . SomeTxBodyError) . hoistEither $
        makeTransactionBody txBodyContent

    firstExceptT ShelleyTxCmdWriteFileError . newExceptT $
      writeFileTextEnvelope fpath Nothing txBody


-- ----------------------------------------------------------------------------
-- Transaction body validation and conversion
--

-- | An enumeration of era-dependent features where we have to check that it
-- is permissible to use this feature in this era.
--
data TxFeature = TxFeatureShelleyAddresses
               | TxFeatureExplicitFees
               | TxFeatureImplicitFees
               | TxFeatureValidityLowerBound
               | TxFeatureValidityUpperBound
               | TxFeatureValidityNoUpperBound
               | TxFeatureTxMetadata
               | TxFeatureAuxScripts
               | TxFeatureWithdrawals
               | TxFeatureCertificates
               | TxFeatureMintValue
               | TxFeatureMultiAssetOutputs
               | TxFeatureScriptWitnesses
               | TxFeatureShelleyKeys
               | TxFeatureWitnessPPData
  deriving Show

txFeatureMismatch :: CardanoEra era
                  -> TxFeature
                  -> ExceptT ShelleyTxCmdError IO a
txFeatureMismatch era feature =
    left (ShelleyTxCmdTxFeatureMismatch (anyCardanoEra era) feature)

validateTxIns :: CardanoEra era
              -> [TxIn]
              -> ExceptT ShelleyTxCmdError IO [TxIn]
validateTxIns _ = return -- no validation or era-checking needed

validateTxOuts :: forall era.
                  CardanoEra era
               -> [TxOutAnyEra]
               -> ExceptT ShelleyTxCmdError IO [TxOut era]
validateTxOuts era = mapM toTxOutInAnyEra
  where
    toTxOutInAnyEra :: TxOutAnyEra
                    -> ExceptT ShelleyTxCmdError IO (TxOut era)
    toTxOutInAnyEra (TxOutAnyEra addr val) = TxOut <$> toAddressInAnyEra addr
                                                   <*> toTxOutValueInAnyEra val

    toAddressInAnyEra :: AddressAny -> ExceptT ShelleyTxCmdError IO (AddressInEra era)
    toAddressInAnyEra addrAny =
      case addrAny of
        AddressByron   bAddr -> return (AddressInEra ByronAddressInAnyEra bAddr)
        AddressShelley sAddr ->
          case cardanoEraStyle era of
            LegacyByronEra -> txFeatureMismatch era TxFeatureShelleyAddresses

            ShelleyBasedEra era' ->
              return (AddressInEra (ShelleyAddressInEra era') sAddr)

    toTxOutValueInAnyEra :: Value -> ExceptT ShelleyTxCmdError IO (TxOutValue era)
    toTxOutValueInAnyEra val =
      case multiAssetSupportedInEra era of
        Left adaOnlyInEra ->
          case valueToLovelace val of
            Just l  -> return (TxOutAdaOnly adaOnlyInEra l)
            Nothing -> txFeatureMismatch era TxFeatureMultiAssetOutputs
        Right multiAssetInEra -> return (TxOutValue multiAssetInEra val)


validateTxFee :: CardanoEra era
              -> Maybe Lovelace
              -> ExceptT ShelleyTxCmdError IO (TxFee era)
validateTxFee era mfee =
    case (txFeesExplicitInEra era, mfee) of
      (Left  implicit, Nothing)  -> return (TxFeeImplicit implicit)
      (Right explicit, Just fee) -> return (TxFeeExplicit explicit fee)

      (Right _, Nothing) -> txFeatureMismatch era TxFeatureImplicitFees
      (Left  _, Just _)  -> txFeatureMismatch era TxFeatureExplicitFees


validateTxValidityLowerBound :: CardanoEra era
                             -> Maybe SlotNo
                             -> ExceptT ShelleyTxCmdError IO
                                        (TxValidityLowerBound era)
validateTxValidityLowerBound _ Nothing = return TxValidityNoLowerBound
validateTxValidityLowerBound era (Just slot) =
    case validityLowerBoundSupportedInEra era of
      Nothing -> txFeatureMismatch era TxFeatureValidityLowerBound
      Just supported -> return (TxValidityLowerBound supported slot)


validateTxValidityUpperBound :: CardanoEra era
                             -> Maybe SlotNo
                             -> ExceptT ShelleyTxCmdError IO
                                        (TxValidityUpperBound era)
validateTxValidityUpperBound era Nothing =
    case validityNoUpperBoundSupportedInEra era of
      Nothing -> txFeatureMismatch era TxFeatureValidityNoUpperBound
      Just supported -> return (TxValidityNoUpperBound supported)
validateTxValidityUpperBound era (Just slot) =
    case validityUpperBoundSupportedInEra era of
      Nothing -> txFeatureMismatch era TxFeatureValidityUpperBound
      Just supported -> return (TxValidityUpperBound supported slot)


validateTxMetadataInEra :: CardanoEra era
                        -> TxMetadataJsonSchema
                        -> [MetadataFile]
                        -> ExceptT ShelleyTxCmdError IO (TxMetadataInEra era)
validateTxMetadataInEra _ _ [] = return TxMetadataNone
validateTxMetadataInEra era schema files =
    case txMetadataSupportedInEra era of
      Nothing -> txFeatureMismatch era TxFeatureTxMetadata
      Just supported -> do
        metadata <- mconcat <$> mapM (readFileTxMetadata schema) files
        return (TxMetadataInEra supported metadata)


validateTxAuxScripts :: CardanoEra era
                     -> [ScriptFile]
                     -> ExceptT ShelleyTxCmdError IO (TxAuxScripts era)
validateTxAuxScripts _ [] = return TxAuxScriptsNone
validateTxAuxScripts era files =
  case auxScriptsSupportedInEra era of
    Nothing -> txFeatureMismatch era TxFeatureAuxScripts
    Just AuxScriptsInAllegraEra -> do
      scripts <- sequence
        [ do script <- firstExceptT ShelleyTxCmdReadJsonFileError $
                         readFileScriptInAnyLang file
             validateScriptSupportedInEra era script
        | ScriptFile file <- files ]
      return $ TxAuxScripts AuxScriptsInAllegraEra scripts
    Just AuxScriptsInMaryEra -> do
      scripts <- sequence
        [ do script <- firstExceptT ShelleyTxCmdReadJsonFileError $
                         readFileScriptInAnyLang file
             validateScriptSupportedInEra era script
        | ScriptFile file <- files ]
      return (TxAuxScripts AuxScriptsInMaryEra scripts)
    Just AuxScriptsInAlonzoEra -> panic "TODO"

validateTxWithdrawals :: CardanoEra era
                      -> [(StakeAddress, Lovelace)]
                      -> ExceptT ShelleyTxCmdError IO (TxWithdrawals era)
validateTxWithdrawals _ [] = return TxWithdrawalsNone
validateTxWithdrawals era withdrawals =
    case withdrawalsSupportedInEra era of
      Nothing -> txFeatureMismatch era TxFeatureWithdrawals
      Just supported -> return (TxWithdrawals supported withdrawals)


validateTxCertificates :: CardanoEra era
                       -> [CertificateFile]
                       -> ExceptT ShelleyTxCmdError IO (TxCertificates era)
validateTxCertificates era certFiles =
  case certificatesSupportedInEra era of
    Nothing
      | null certFiles -> return TxCertificatesNone
      | otherwise      -> txFeatureMismatch era TxFeatureCertificates
    Just supported -> do
      certs <- sequence
                 [ firstExceptT ShelleyTxCmdReadTextViewFileError . newExceptT $
                     readFileTextEnvelope AsCertificate certFile
                 | CertificateFile certFile <- certFiles ]
      return $ TxCertificates supported certs


validateTxUpdateProposal :: CardanoEra era
                         -> Maybe UpdateProposalFile
                         -> ExceptT ShelleyTxCmdError IO (TxUpdateProposal era)
validateTxUpdateProposal _ Nothing = return TxUpdateProposalNone
validateTxUpdateProposal era (Just (UpdateProposalFile file)) =
    case updateProposalSupportedInEra era of
      Nothing -> txFeatureMismatch era TxFeatureCertificates
      Just supported -> do
         prop <- firstExceptT ShelleyTxCmdReadTextViewFileError $ newExceptT $
                   readFileTextEnvelope AsUpdateProposal file
         return (TxUpdateProposal supported prop)


validateTxMintValue :: CardanoEra era
                    -> Maybe Value
                    -> ExceptT ShelleyTxCmdError IO (TxMintValue era)
validateTxMintValue _ Nothing = return TxMintNone
validateTxMintValue era (Just v) =
    case multiAssetSupportedInEra era of
       Left _ -> txFeatureMismatch era TxFeatureMintValue
       Right supported -> return (TxMintValue supported v)


-- ----------------------------------------------------------------------------
-- Transaction signing
--

runTxSign :: TxBodyFile
          -> [WitnessSigningData]
          -> Maybe NetworkId
          -> TxFile
          -> ExceptT ShelleyTxCmdError IO ()
runTxSign (TxBodyFile txbodyFile) witSigningData mnw (TxFile txFile) = do

  InAnyShelleyBasedEra _era txbody <-
        --TODO: in principle we should be able to support Byron era txs too
        onlyInShelleyBasedEras "sign for Byron era transactions"
    =<< readFileTxBody txbodyFile

  sks    <- firstExceptT ShelleyTxCmdReadWitnessSigningDataError $
              mapM readWitnessSigningData witSigningData

  let (sksByron, sksShelley, scsShelley) = partitionSomeWitnesses $ map categoriseSomeWitness sks

  scsShelley' <- mapM (validateScriptSupportedInEra cardanoEra) scsShelley

  -- Byron witnesses require the network ID. This can either be provided
  -- directly or derived from a provided Byron address.
  byronWitnesses <- firstExceptT ShelleyTxCmdBootstrapWitnessError
    . hoistEither
    $ mkShelleyBootstrapWitnesses mnw txbody sksByron

  let shelleyKeyWitnesses = map (makeShelleyKeyWitness txbody) sksShelley
      shelleyScriptWitnesses = map makeScriptWitness scsShelley'
      shelleyWitnesses = shelleyKeyWitnesses ++ shelleyScriptWitnesses
      tx = makeSignedTransaction (byronWitnesses ++ shelleyWitnesses) txbody

  firstExceptT ShelleyTxCmdWriteFileError . newExceptT $
    writeFileTextEnvelope txFile Nothing tx


-- ----------------------------------------------------------------------------
-- Transaction submission
--


runTxSubmit
  :: AnyConsensusModeParams
  -> NetworkId
  -> FilePath
  -> ExceptT ShelleyTxCmdError IO ()
runTxSubmit (AnyConsensusModeParams cModeParams) network txFile = do
    SocketPath sockPath <- firstExceptT ShelleyTxCmdSocketEnvError readEnvSocketPath

    InAnyCardanoEra era tx <- readFileTx txFile
    let cMode = AnyConsensusMode $ consensusModeOnly cModeParams
    eraInMode <- hoistMaybe
                   (ShelleyTxCmdEraConsensusModeMismatch txFile cMode (AnyCardanoEra era))
                   (toEraInMode era $ consensusModeOnly cModeParams)
    let txInMode = TxInMode tx eraInMode
        localNodeConnInfo = LocalNodeConnectInfo
                              { localConsensusModeParams = cModeParams
                              , localNodeNetworkId = network
                              , localNodeSocketPath = sockPath
                              }

    res <- liftIO $ submitTxToNodeLocal localNodeConnInfo txInMode
    case res of
      Net.Tx.SubmitSuccess -> liftIO $ putTextLn "Transaction successfully submitted."
      Net.Tx.SubmitFail reason ->
        case reason of
          TxValidationErrorInMode err _eraInMode -> left . ShelleyTxCmdTxSubmitError . Text.pack $ show err
          TxValidationEraMismatch mismatchErr -> left $ ShelleyTxCmdTxSubmitErrorEraMismatch mismatchErr

-- ----------------------------------------------------------------------------
-- Transaction fee calculation
--

runTxCalculateMinFee
  :: TxBodyFile
  -> Maybe NetworkId
  -> ProtocolParamsSourceSpec
  -> TxInCount
  -> TxOutCount
  -> TxShelleyWitnessCount
  -> TxByronWitnessCount
  -> ExceptT ShelleyTxCmdError IO ()
runTxCalculateMinFee (TxBodyFile txbodyFile) nw protocolParamsSourceSpec
                     (TxInCount nInputs) (TxOutCount nOutputs)
                     (TxShelleyWitnessCount nShelleyKeyWitnesses)
                     (TxByronWitnessCount nByronKeyWitnesses) = do

    InAnyShelleyBasedEra sbe txbody <-
          --TODO: in principle we should be able to support Byron era txs too
          onlyInShelleyBasedEras "calculate-min-fee for Byron era transactions"
      =<< readFileTxBody txbodyFile
    case protocolParamsSourceSpec of
      ParamsFromGenesis genFile -> do pparams <- getProtocolParametersFromGen genFile
                                      let tx = makeSignedTransaction [] txbody
                                          Lovelace fee = estimateTransactionFee sbe
                                                               (fromMaybe Mainnet nw)
                                                               (protocolParamTxFeeFixed pparams)
                                                               (protocolParamTxFeePerByte pparams)
                                                               tx
                                                               nInputs nOutputs
                                                               nByronKeyWitnesses nShelleyKeyWitnesses

                                      liftIO $ putStrLn $ (show fee :: String) <> " Lovelace"
      ParamsFromFile pParamFile -> do pparams <- getProtocolParametersFromFile sbe pParamFile
                                      let tx = makeSignedTransaction [] txbody
                                          Lovelace fee = estimateTransactionFee sbe
                                                               (fromMaybe Mainnet nw)
                                                               (protocolParamTxFeeFixed pparams)
                                                               (protocolParamTxFeePerByte pparams)
                                                               tx
                                                               nInputs nOutputs
                                                               nByronKeyWitnesses nShelleyKeyWitnesses

                                      liftIO $ putStrLn $ (show fee :: String) <> " Lovelace"
 where
  getProtocolParametersFromGen :: GenesisFile
                               -> ExceptT ShelleyTxCmdError IO (ProtocolParameters ShelleyEra)
  getProtocolParametersFromGen (GenesisFile f) =
    fromShelleyPParams ShelleyBasedEraShelley . sgProtocolParams
      <$> firstExceptT ShelleyTxCmdGenesisCmdError
            (readShelleyGenesis f identity)

  getProtocolParametersFromFile :: IsCardanoEra era
                                => ShelleyBasedEra era
                                -> ProtocolParamsFile
                                -> ExceptT ShelleyTxCmdError IO (ProtocolParameters era)
  getProtocolParametersFromFile sbe fp = readProtocolParameters sbe fp

runTxCreatePolicyId :: ScriptFile -> ExceptT ShelleyTxCmdError IO ()
runTxCreatePolicyId (ScriptFile sFile) = do
  ScriptInAnyLang _ script <- firstExceptT ShelleyTxCmdReadJsonFileError $ readFileScriptInAnyLang sFile
  liftIO . putTextLn . serialiseToRawBytesHexText $ hashScript script

--TODO: eliminate this and get only the necessary params, and get them in a more
-- helpful way rather than requiring them as a local file.
readProtocolParameters :: IsCardanoEra era
                       => ShelleyBasedEra era
                       -> ProtocolParamsFile
                       -> ExceptT ShelleyTxCmdError IO (ProtocolParameters era)
readProtocolParameters _ (ProtocolParamsFile fpath) = do
  pparams <- handleIOExceptT (ShelleyTxCmdReadFileError . FileIOError fpath) $ LBS.readFile fpath
  firstExceptT (ShelleyTxCmdAesonDecodeProtocolParamsError fpath . Text.pack) . hoistEither $
    Aeson.eitherDecode' pparams

data SomeWitness
  = AByronSigningKey           (SigningKey ByronKey) (Maybe (Address ByronAddr))
  | APaymentSigningKey         (SigningKey PaymentKey)
  | APaymentExtendedSigningKey (SigningKey PaymentExtendedKey)
  | AStakeSigningKey           (SigningKey StakeKey)
  | AStakeExtendedSigningKey   (SigningKey StakeExtendedKey)
  | AStakePoolSigningKey       (SigningKey StakePoolKey)
  | AGenesisSigningKey         (SigningKey GenesisKey)
  | AGenesisExtendedSigningKey (SigningKey GenesisExtendedKey)
  | AGenesisDelegateSigningKey (SigningKey GenesisDelegateKey)
  | AGenesisDelegateExtendedSigningKey
                               (SigningKey GenesisDelegateExtendedKey)
  | AGenesisUTxOSigningKey     (SigningKey GenesisUTxOKey)
  | AShelleyScript              ScriptInAnyLang


-- | Error reading the data required to construct a key witness.
data ReadWitnessSigningDataError
  = ReadWitnessSigningDataSigningKeyDecodeError !(FileError InputDecodeError)
  | ReadWitnessSigningDataScriptError !(FileError JsonDecodeError)
  | ReadWitnessSigningDataSigningKeyAndAddressMismatch
  -- ^ A Byron address was specified alongside a non-Byron signing key.
  deriving Show

-- | Render an error message for a 'ReadWitnessSigningDataError'.
renderReadWitnessSigningDataError :: ReadWitnessSigningDataError -> Text
renderReadWitnessSigningDataError err =
  case err of
    ReadWitnessSigningDataSigningKeyDecodeError fileErr ->
      "Error reading signing key: " <> Text.pack (displayError fileErr)
    ReadWitnessSigningDataScriptError fileErr ->
      "Error reading script: " <> Text.pack (displayError fileErr)
    ReadWitnessSigningDataSigningKeyAndAddressMismatch ->
      "Only a Byron signing key may be accompanied by a Byron address."

readWitnessSigningData
  :: WitnessSigningData
  -> ExceptT ReadWitnessSigningDataError IO SomeWitness
readWitnessSigningData (ScriptWitnessSigningData (ScriptFile fp)) =
    firstExceptT ReadWitnessSigningDataScriptError $
      AShelleyScript <$> readFileScriptInAnyLang fp

readWitnessSigningData (KeyWitnessSigningData skFile mbByronAddr) = do
    res <- firstExceptT ReadWitnessSigningDataSigningKeyDecodeError
      . newExceptT
      $ readSigningKeyFileAnyOf bech32FileTypes textEnvFileTypes skFile
    case (res, mbByronAddr) of
      (AByronSigningKey _ _, Just _) -> pure res
      (AByronSigningKey _ _, Nothing) -> pure res
      (_, Nothing) -> pure res
      (_, Just _) ->
        -- A Byron address should only be specified along with a Byron signing key.
        left ReadWitnessSigningDataSigningKeyAndAddressMismatch
  where
    textEnvFileTypes =
      [ FromSomeType (AsSigningKey AsByronKey)
                          (`AByronSigningKey` mbByronAddr)
      , FromSomeType (AsSigningKey AsPaymentKey)
                          APaymentSigningKey
      , FromSomeType (AsSigningKey AsPaymentExtendedKey)
                          APaymentExtendedSigningKey
      , FromSomeType (AsSigningKey AsStakeKey)
                          AStakeSigningKey
      , FromSomeType (AsSigningKey AsStakeExtendedKey)
                          AStakeExtendedSigningKey
      , FromSomeType (AsSigningKey AsStakePoolKey)
                          AStakePoolSigningKey
      , FromSomeType (AsSigningKey AsGenesisKey)
                          AGenesisSigningKey
      , FromSomeType (AsSigningKey AsGenesisExtendedKey)
                          AGenesisExtendedSigningKey
      , FromSomeType (AsSigningKey AsGenesisDelegateKey)
                          AGenesisDelegateSigningKey
      , FromSomeType (AsSigningKey AsGenesisDelegateExtendedKey)
                          AGenesisDelegateExtendedSigningKey
      , FromSomeType (AsSigningKey AsGenesisUTxOKey)
                          AGenesisUTxOSigningKey
      ]

    bech32FileTypes =
      [ FromSomeType (AsSigningKey AsByronKey)
                          (`AByronSigningKey` mbByronAddr)
      , FromSomeType (AsSigningKey AsPaymentKey)
                          APaymentSigningKey
      , FromSomeType (AsSigningKey AsPaymentExtendedKey)
                          APaymentExtendedSigningKey
      , FromSomeType (AsSigningKey AsStakeKey)
                          AStakeSigningKey
      , FromSomeType (AsSigningKey AsStakeExtendedKey)
                          AStakeExtendedSigningKey
      , FromSomeType (AsSigningKey AsStakePoolKey)
                          AStakePoolSigningKey
      ]

partitionSomeWitnesses
  :: [ByronOrShelleyWitness]
  -> ( [ShelleyBootstrapWitnessSigningKeyData]
     , [ShelleyWitnessSigningKey]
     , [ScriptInAnyLang]
     )
partitionSomeWitnesses = reversePartitionedWits . foldl' go mempty
  where
    reversePartitionedWits (bw, skw, ssw) =
      (reverse bw, reverse skw, reverse ssw)

    go (byronAcc, shelleyKeyAcc, shelleyScriptAcc) byronOrShelleyWit =
      case byronOrShelleyWit of
        AByronWitness byronWit ->
          (byronWit:byronAcc, shelleyKeyAcc, shelleyScriptAcc)
        AShelleyKeyWitness shelleyKeyWit ->
          (byronAcc, shelleyKeyWit:shelleyKeyAcc, shelleyScriptAcc)
        AShelleyScriptWitness shelleyScriptWit ->
          (byronAcc, shelleyKeyAcc, shelleyScriptWit:shelleyScriptAcc)


-- | Some kind of Byron or Shelley witness.
data ByronOrShelleyWitness
  = AByronWitness !ShelleyBootstrapWitnessSigningKeyData
  | AShelleyKeyWitness !ShelleyWitnessSigningKey
  | AShelleyScriptWitness !ScriptInAnyLang

categoriseSomeWitness :: SomeWitness -> ByronOrShelleyWitness
categoriseSomeWitness swsk =
  case swsk of
    AByronSigningKey           sk addr -> AByronWitness (ShelleyBootstrapWitnessSigningKeyData sk addr)
    APaymentSigningKey         sk      -> AShelleyKeyWitness (WitnessPaymentKey         sk)
    APaymentExtendedSigningKey sk      -> AShelleyKeyWitness (WitnessPaymentExtendedKey sk)
    AStakeSigningKey           sk      -> AShelleyKeyWitness (WitnessStakeKey           sk)
    AStakeExtendedSigningKey   sk      -> AShelleyKeyWitness (WitnessStakeExtendedKey   sk)
    AStakePoolSigningKey       sk      -> AShelleyKeyWitness (WitnessStakePoolKey       sk)
    AGenesisSigningKey         sk      -> AShelleyKeyWitness (WitnessGenesisKey sk)
    AGenesisExtendedSigningKey sk      -> AShelleyKeyWitness (WitnessGenesisExtendedKey sk)
    AGenesisDelegateSigningKey sk      -> AShelleyKeyWitness (WitnessGenesisDelegateKey sk)
    AGenesisDelegateExtendedSigningKey sk
                                       -> AShelleyKeyWitness (WitnessGenesisDelegateExtendedKey sk)
    AGenesisUTxOSigningKey     sk      -> AShelleyKeyWitness (WitnessGenesisUTxOKey     sk)
    AShelleyScript             scr     -> AShelleyScriptWitness scr

-- | Data required for constructing a Shelley bootstrap witness.
data ShelleyBootstrapWitnessSigningKeyData
  = ShelleyBootstrapWitnessSigningKeyData
      !(SigningKey ByronKey)
      -- ^ Byron signing key.
      !(Maybe (Address ByronAddr))
      -- ^ An optionally specified Byron address.
      --
      -- If specified, both the network ID and derivation path are extracted
      -- from the address and used in the construction of the Byron witness.

-- | Error constructing a Shelley bootstrap witness (i.e. a Byron key witness
-- in the Shelley era).
data ShelleyBootstrapWitnessError
  = MissingNetworkIdOrByronAddressError
  -- ^ Neither a network ID nor a Byron address were provided to construct the
  -- Shelley bootstrap witness. One or the other is required.
  deriving Show

-- | Render an error message for a 'ShelleyBootstrapWitnessError'.
renderShelleyBootstrapWitnessError :: ShelleyBootstrapWitnessError -> Text
renderShelleyBootstrapWitnessError MissingNetworkIdOrByronAddressError =
  "Transactions witnessed by a Byron signing key must be accompanied by a "
    <> "network ID. Either provide a network ID or provide a Byron "
    <> "address with each Byron signing key (network IDs can be derived "
    <> "from Byron addresses)."

-- | Construct a Shelley bootstrap witness (i.e. a Byron key witness in the
-- Shelley era).
mkShelleyBootstrapWitness
  :: IsShelleyBasedEra era
  => Maybe NetworkId
  -> TxBody era
  -> ShelleyBootstrapWitnessSigningKeyData
  -> Either ShelleyBootstrapWitnessError (Witness era)
mkShelleyBootstrapWitness Nothing _ (ShelleyBootstrapWitnessSigningKeyData _ Nothing) =
  Left MissingNetworkIdOrByronAddressError
mkShelleyBootstrapWitness (Just nw) txBody (ShelleyBootstrapWitnessSigningKeyData skey Nothing) =
  Right $ makeShelleyBootstrapWitness (WitnessNetworkId nw) txBody skey
mkShelleyBootstrapWitness _ txBody (ShelleyBootstrapWitnessSigningKeyData skey (Just addr)) =
  Right $ makeShelleyBootstrapWitness (WitnessByronAddress addr) txBody skey

-- | Attempt to construct Shelley bootstrap witnesses until an error is
-- encountered.
mkShelleyBootstrapWitnesses
  :: IsShelleyBasedEra era
  => Maybe NetworkId
  -> TxBody era
  -> [ShelleyBootstrapWitnessSigningKeyData]
  -> Either ShelleyBootstrapWitnessError [Witness era]
mkShelleyBootstrapWitnesses mnw txBody =
  mapM (mkShelleyBootstrapWitness mnw txBody)


runTxGetTxId :: InputTxFile -> ExceptT ShelleyTxCmdError IO ()
runTxGetTxId txfile = do
    InAnyCardanoEra _era txbody <-
      case txfile of
        InputTxBodyFile (TxBodyFile txbodyFile) -> readFileTxBody txbodyFile
        InputTxFile (TxFile txFile) -> do
          InAnyCardanoEra era tx <- readFileTx txFile
          return . InAnyCardanoEra era $ getTxBody tx

    liftIO $ BS.putStrLn $ serialiseToRawBytesHex (getTxId txbody)

runTxView :: InputTxFile -> ExceptT ShelleyTxCmdError IO ()
runTxView txfile = do
  InAnyCardanoEra era txbody <-
    case txfile of
      InputTxBodyFile (TxBodyFile txbodyFile) -> readFileTxBody txbodyFile
      InputTxFile (TxFile txFile) -> do
        InAnyCardanoEra era tx <- readFileTx txFile
        return . InAnyCardanoEra era $ getTxBody tx
  liftIO $ BS.putStr $ friendlyTxBodyBS era txbody

runTxCreateWitness
  :: TxBodyFile
  -> WitnessSigningData
  -> Maybe NetworkId
  -> OutputFile
  -> ExceptT ShelleyTxCmdError IO ()
runTxCreateWitness (TxBodyFile txbodyFile) witSignData mbNw (OutputFile oFile) = do

  InAnyShelleyBasedEra _era txbody <-
        --TODO: in principle we should be able to support Byron era txs too
        onlyInShelleyBasedEras "witness for Byron era transactions"
    =<< readFileTxBody txbodyFile
  -- We use the era of the tx we read to determine the era we use for the rest:

  someWit <- firstExceptT ShelleyTxCmdReadWitnessSigningDataError
    $ readWitnessSigningData witSignData

  witness <-
    case categoriseSomeWitness someWit of
      -- Byron witnesses require the network ID. This can either be provided
      -- directly or derived from a provided Byron address.
      AByronWitness bootstrapWitData ->
        firstExceptT ShelleyTxCmdBootstrapWitnessError
          . hoistEither
          $ mkShelleyBootstrapWitness mbNw txbody bootstrapWitData
      AShelleyKeyWitness skShelley ->
        pure $ makeShelleyKeyWitness txbody skShelley
      AShelleyScriptWitness script ->
        makeScriptWitness <$> validateScriptSupportedInEra cardanoEra script

  firstExceptT ShelleyTxCmdWriteFileError
    . newExceptT
    $ writeFileTextEnvelope oFile Nothing witness


runTxSignWitness
  :: TxBodyFile
  -> [WitnessFile]
  -> OutputFile
  -> ExceptT ShelleyTxCmdError IO ()
runTxSignWitness (TxBodyFile txbodyFile) witnessFiles (OutputFile oFp) = do

    InAnyCardanoEra era txbody  <- readFileTxBody txbodyFile
    InAnyShelleyBasedEra _ _ <-
          --TODO: in principle we should be able to support Byron era txs too
          onlyInShelleyBasedEras "sign for Byron era transactions"
                                 (InAnyCardanoEra era txbody)

    witnesses <-
      sequence
        [ do InAnyCardanoEra era' witness <- readFileWitness file
             case testEquality era era' of
               Nothing   -> left $ ShelleyTxCmdWitnessEraMismatch
                                     (AnyCardanoEra era)
                                     (AnyCardanoEra era')
                                     witnessFile
               Just Refl -> return witness
        | witnessFile@(WitnessFile file) <- witnessFiles ]

    let tx = makeSignedTransaction witnesses txbody
    firstExceptT ShelleyTxCmdWriteFileError
      . newExceptT
      $ writeFileTextEnvelope oFp Nothing tx


-- ----------------------------------------------------------------------------
-- Reading files in any era
--

readFileWitness :: FilePath
                -> ExceptT ShelleyTxCmdError IO (InAnyCardanoEra Witness)
readFileWitness = readFileInAnyCardanoEra AsWitness


readFileTxBody :: FilePath
               -> ExceptT ShelleyTxCmdError IO (InAnyCardanoEra TxBody)
readFileTxBody = readFileInAnyCardanoEra AsTxBody


readFileTx :: FilePath -> ExceptT ShelleyTxCmdError IO (InAnyCardanoEra Tx)
readFileTx = readFileInAnyCardanoEra AsTx


readFileInAnyCardanoEra
  :: ( HasTextEnvelope (thing ByronEra)
     , HasTextEnvelope (thing ShelleyEra)
     , HasTextEnvelope (thing AllegraEra)
     , HasTextEnvelope (thing MaryEra)
     )
  => (forall era. AsType era -> AsType (thing era))
  -> FilePath
  -> ExceptT ShelleyTxCmdError IO
            (InAnyCardanoEra thing)
readFileInAnyCardanoEra asThing file =
    firstExceptT ShelleyTxCmdReadTextViewFileError
  . newExceptT
  $ readFileTextEnvelopeAnyOf
      [ FromSomeType (asThing AsByronEra)   (InAnyCardanoEra ByronEra)
      , FromSomeType (asThing AsShelleyEra) (InAnyCardanoEra ShelleyEra)
      , FromSomeType (asThing AsAllegraEra) (InAnyCardanoEra AllegraEra)
      , FromSomeType (asThing AsMaryEra)    (InAnyCardanoEra MaryEra)
      ]
      file

-- | Constrain the era to be Shelley based. Fail for the Byron era.
--
onlyInShelleyBasedEras :: Text
                       -> InAnyCardanoEra a
                       -> ExceptT ShelleyTxCmdError IO
                                  (InAnyShelleyBasedEra a)
onlyInShelleyBasedEras notImplMsg (InAnyCardanoEra era x) =
    case cardanoEraStyle era of
      LegacyByronEra       -> left (ShelleyTxCmdNotImplemented notImplMsg)
      ShelleyBasedEra era' -> return (InAnyShelleyBasedEra era' x)


-- ----------------------------------------------------------------------------
-- Reading other files
--

readFileScriptInAnyLang :: FilePath
                        -> ExceptT (FileError JsonDecodeError) IO ScriptInAnyLang
readFileScriptInAnyLang path =
    newExceptT $ readFileJSON AsScriptInAnyLang path

validateScriptSupportedInEra :: CardanoEra era
                             -> ScriptInAnyLang
                             -> ExceptT ShelleyTxCmdError IO (ScriptInEra era)
validateScriptSupportedInEra era script@(ScriptInAnyLang lang _) =
    case toScriptInEra era script of
      Nothing -> left $ ShelleyTxCmdScriptLanguageNotSupportedInEra
                          (AnyScriptLanguage lang) (anyCardanoEra era)
      Just script' -> pure script'


-- ----------------------------------------------------------------------------
-- Transaction metadata
--

readFileTxMetadata :: TxMetadataJsonSchema -> MetadataFile
                   -> ExceptT ShelleyTxCmdError IO TxMetadata
readFileTxMetadata mapping (MetadataFileJSON fp) = do
    bs <- handleIOExceptT (ShelleyTxCmdReadFileError . FileIOError fp) $
          LBS.readFile fp
    v  <- firstExceptT (ShelleyTxCmdMetadataJsonParseError fp) $
          hoistEither $
            Aeson.eitherDecode' bs
    txMetadata <- firstExceptT (ShelleyTxCmdMetadataConversionError fp) $ hoistEither $
      metadataFromJson mapping v
    firstExceptT (ShelleyTxCmdMetaValidationError fp) $ hoistEither $ do
        validateTxMetadata txMetadata
        return txMetadata

readFileTxMetadata _ (MetadataFileCBOR fp) = do
    bs <- handleIOExceptT (ShelleyTxCmdReadFileError . FileIOError fp) $
          BS.readFile fp
    txMetadata <- firstExceptT (ShelleyTxCmdMetaDecodeError fp) $ hoistEither $
      deserialiseFromCBOR AsTxMetadata bs
    firstExceptT (ShelleyTxCmdMetaValidationError fp) $ hoistEither $ do
        validateTxMetadata txMetadata
        return txMetadata
