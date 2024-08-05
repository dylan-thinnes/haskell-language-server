-- Retrieve the list of errors from the HaskellErrorIndex via its API
{-# LANGUAGE CPP #-}

module Development.IDE.Core.HaskellErrorIndex where

import           Control.Exception                 (tryJust)
import           Data.Aeson                        (FromJSON (..), withObject,
                                                    (.:))
import qualified Data.Map                          as M
import qualified Data.Text                         as T
import           Development.IDE.Types.Diagnostics
import           GHC.Driver.Errors.Types           (GhcMessage)
#if MIN_VERSION_ghc(9,6,1)
import           GHC.Types.Error                   (diagnosticCode)
#endif
import           Ide.Logger                        (Pretty (..), Priority (..),
                                                    Recorder, WithPriority,
                                                    logWith, vcat)
import           Language.LSP.Protocol.Types       (CodeDescription (..),
                                                    Uri (..))
import           Network.HTTP.Simple               (HttpException,
                                                    JSONException,
                                                    getResponseBody, httpJSON)

data Log
  = LogHaskellErrorIndexInitialized
  | LogHaskellErrorIndexJSONError JSONException
  | LogHaskellErrorIndexHTTPError HttpException
  deriving (Show)

instance Pretty Log where
  pretty = \case
    LogHaskellErrorIndexInitialized -> "Initialized Haskell Error Index from internet"
    LogHaskellErrorIndexJSONError err ->
      vcat
        [ "Failed to initialize Haskell Error Index due to a JSON error:"
        , pretty (show err)
        ]
    LogHaskellErrorIndexHTTPError err ->
      vcat
        [ "Failed to initialize Haskell Error Index due to an HTTP error:"
        , pretty (show err)
        ]

newtype HaskellErrorIndex = HaskellErrorIndex (M.Map T.Text HEIError)
  deriving (Show, Eq, Ord)

data HEIError = HEIError
  { code  :: T.Text
  , route :: T.Text
  }
  deriving (Show, Eq, Ord)

errorsToIndex :: [HEIError] -> HaskellErrorIndex
errorsToIndex errs = HaskellErrorIndex $ M.fromList $ map (\err -> (code err, err)) errs

instance FromJSON HEIError where
  parseJSON =
    withObject "HEIError" $ \v ->
      HEIError
        <$> v .: "code"
        <*> v .: "route"

instance FromJSON HaskellErrorIndex where
  parseJSON = fmap errorsToIndex <$> parseJSON

initHaskellErrorIndex :: Recorder (WithPriority Log) -> IO (Maybe HaskellErrorIndex)
#if MIN_VERSION_ghc(9,6,1)
initHaskellErrorIndex recorder = do
  res <- tryJust handleJSONError $ tryJust handleHttpError $ httpJSON "https://errors.haskell.org/api/errors.json"
  case res of
    Left jsonErr -> do
      logWith recorder Info (LogHaskellErrorIndexJSONError jsonErr)
      pure Nothing
    Right (Left httpErr) -> do
      logWith recorder Info (LogHaskellErrorIndexHTTPError httpErr)
      pure Nothing
    Right (Right res) -> pure $ Just (getResponseBody res)
  where
    handleJSONError :: JSONException -> Maybe JSONException
    handleJSONError = Just
    handleHttpError :: HttpException -> Maybe HttpException
    handleHttpError = Just
#else
initHaskellErrorIndex recorder = pure Nothing
#endif

heiGetError :: HaskellErrorIndex -> GhcMessage -> Maybe HEIError
#if MIN_VERSION_ghc(9,6,1)
heiGetError (HaskellErrorIndex index) msg
  | Just code <- diagnosticCode msg
  = showGhcCode code `M.lookup` index
  | otherwise
  = Nothing
#else
heiGetError (HaskellErrorIndex index) msg
  = Nothing
#endif

attachHeiErrorCodeDescription :: HEIError -> Diagnostic -> Diagnostic
attachHeiErrorCodeDescription heiError diag =
  diag
    { _codeDescription = Just $ CodeDescription $ Uri $ "https://errors.haskell.org/" <> route heiError
    }