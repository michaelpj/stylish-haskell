{-# LANGUAGE BlockArguments             #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE DoAndIfThenElse            #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE RecordWildCards            #-}
module Language.Haskell.Stylish.Printer
  ( Printer(..)
  , PrinterConfig(..)
  , PrinterState(..)

    -- * Alias
  , P

    -- * Functions to use the printer
  , runPrinter
  , runPrinter_

    -- ** Combinators
  , comma
  , dot
  -- , getAnnot
  , getCurrentLine
  , getCurrentLineLength
  -- , getDocstrPrev
  , newline
  , parenthesize
  -- , peekNextCommentPos
  , prefix
  , putComment
  , putMaybeLineComment
  -- , putEolComment
  , putOutputable
  -- , putAllSpanComments
  , putCond
  , putType
  , putRdrName
  , putText
  -- , removeCommentTo
  -- , removeCommentToEnd
  -- , removeLineComment
  , sep
  -- , groupAttachedComments
  -- , groupWithoutComments
  , space
  , spaces
  , suffix
  , pad

    -- ** Advanced combinators
  , withColumns
  , modifyCurrentLine
  , wrapping
  ) where

--------------------------------------------------------------------------------
import           Prelude                         hiding (lines)

--------------------------------------------------------------------------------
import qualified GHC.Hs                          as GHC
import           GHC.Hs.Extension                (GhcPs)
import qualified GHC.Types.Basic                 as GHC
import           GHC.Types.Name.Reader           (RdrName (..))
import           GHC.Types.SrcLoc                (GenLocated (..))
import qualified GHC.Types.SrcLoc                as GHC
import qualified GHC.Unit.Module.Name            as GHC
import           GHC.Utils.Outputable            (Outputable)

--------------------------------------------------------------------------------
import           Control.Monad                   (forM_, replicateM_)
import           Control.Monad.Reader            (MonadReader, ReaderT (..),
                                                  asks, local)
import           Control.Monad.State             (MonadState, State, get, gets,
                                                  modify, put, runState)
import           Data.List                       (foldl')

--------------------------------------------------------------------------------
import           Language.Haskell.Stylish.GHC    (showOutputable)
import           Language.Haskell.Stylish.Module (Lines)

-- | Shorthand for 'Printer' monad
type P = Printer

-- | Printer that keeps state of file
newtype Printer a = Printer (ReaderT PrinterConfig (State PrinterState) a)
  deriving (Applicative, Functor, Monad, MonadReader PrinterConfig, MonadState PrinterState)

-- | Configuration for printer, currently empty
data PrinterConfig = PrinterConfig
    { columns :: !(Maybe Int)
    }

-- | State of printer
data PrinterState = PrinterState
  { lines       :: !Lines
  , linePos     :: !Int
  , currentLine :: !String
  }

-- | Run printer to get printed lines out of module as well as return value of monad
runPrinter :: PrinterConfig -> Printer a -> (a, Lines)
runPrinter cfg (Printer printer) =
  let
    (a, PrinterState parsedLines _ startedLine) = runReaderT printer cfg `runState` PrinterState [] 0 ""
  in
    (a, parsedLines <> if startedLine == [] then [] else [startedLine])

-- | Run printer to get printed lines only
runPrinter_ :: PrinterConfig -> Printer a -> Lines
runPrinter_ cfg printer = snd (runPrinter cfg printer)

-- | Print text
putText :: String -> P ()
putText txt = do
  l <- gets currentLine
  modify \s -> s { currentLine = l <> txt }

-- | Check condition post action, and use fallback if false
putCond :: (PrinterState -> Bool) -> P b -> P b -> P b
putCond p action fallback = do
  prevState <- get
  res <- action
  currState <- get
  if p currState then pure res
  else put prevState >> fallback

-- | Print an 'Outputable'
putOutputable :: Outputable a => a -> P ()
putOutputable = putText . showOutputable

-- | Put all comments that has positions within 'SrcSpan' and separate by
--   passed @P ()@
{-
putAllSpanComments :: P () -> SrcSpan -> P ()
putAllSpanComments suff = \case
  UnhelpfulSpan _ -> pure ()
  RealSrcSpan rspan -> do
    cmts <- removeComments \(L rloc _) ->
      srcSpanStartLine rloc >= srcSpanStartLine rspan &&
      srcSpanEndLine rloc <= srcSpanEndLine rspan

    forM_ cmts (\c -> putComment c >> suff)
-}

-- | Print any comment
putComment :: GHC.EpaComment -> P ()
putComment epaComment = case GHC.ac_tok epaComment of
  GHC.EpaLineComment s     -> putText s
  GHC.EpaDocCommentNext s  -> putText s
  GHC.EpaDocCommentPrev s  -> putText s
  GHC.EpaDocCommentNamed s -> putText s
  GHC.EpaDocSection _ s    -> putText s
  GHC.EpaDocOptions s      -> putText s
  GHC.EpaBlockComment s    -> putText s
  GHC.EpaEofComment        -> pure ()

putMaybeLineComment :: Maybe GHC.EpaComment -> P ()
putMaybeLineComment = \case
    Nothing  -> pure ()
    Just cmt -> space >> putComment cmt

-- | Given the current start line of 'SrcSpan', remove and put EOL comment for same line
{-
putEolComment :: SrcSpan -> P ()
putEolComment = \case
  RealSrcSpan rspan -> do
    cmt <- removeComment \case
      L rloc epaComment | GHC.EpaLineComment s <- GHC.ac_tok epaComment ->
        and
          [ srcSpanStartLine rspan == srcSpanStartLine rloc
          , not ("-- ^" `isPrefixOf` s)
          , not ("-- |" `isPrefixOf` s)
          ]
      _ -> False
    forM_ cmt (\c -> space >> putComment c)
  UnhelpfulSpan _ -> pure ()
-}

-- | Print a 'RdrName'
putRdrName :: GenLocated GHC.SrcSpanAnnN RdrName -> P ()
putRdrName rdrName = case GHC.unLoc rdrName of
    Unqual name -> do
      let (pre, post) = nameAnnAdornments $
            GHC.epAnnAnnsL $ GHC.ann $ GHC.getLoc rdrName
      putText pre
      putText (showOutputable name)
      putText post
    Qual modulePrefix name ->
      putModuleName modulePrefix >> dot >> putText (showOutputable name)
    Orig _ name ->
      putText (showOutputable name)
    Exact name ->
      putText (showOutputable name)

nameAnnAdornments :: [GHC.NameAnn] -> (String, String)
nameAnnAdornments = foldl'
    (\(accl, accr) nameAnn ->
        let (l, r) = nameAnnAdornment nameAnn in (accl ++ l, r ++ accr))
    (mempty, mempty)

nameAnnAdornment :: GHC.NameAnn -> (String, String)
nameAnnAdornment = \case
    GHC.NameAnn {..}       -> fromAdornment nann_adornment
    GHC.NameAnnCommas {..} -> fromAdornment nann_adornment
    GHC.NameAnnOnly {..}   -> fromAdornment nann_adornment
    GHC.NameAnnRArrow {}   -> (mempty, mempty)
    GHC.NameAnnQuote {}    -> ("'", mempty)
    GHC.NameAnnTrailing {} -> (mempty, mempty)
  where
    fromAdornment GHC.NameParens     = ("(", ")")
    fromAdornment GHC.NameBackquotes = ("`", "`")
    fromAdornment GHC.NameParensHash = ("#(", "#)")
    fromAdornment GHC.NameSquare     = ("[", "]")

-- | Print module name
putModuleName :: GHC.ModuleName -> P ()
putModuleName = putText . GHC.moduleNameString

-- | Print type
putType :: GHC.LHsType GhcPs -> P ()
putType ltp = case GHC.unLoc ltp of
  GHC.HsFunTy _ arrowTp argTp funTp -> do
    putOutputable argTp
    space
    case arrowTp of
        GHC.HsUnrestrictedArrow {} -> putText "->"
        GHC.HsLinearArrow {}       -> putText "%1 ->"
        GHC.HsExplicitMult {}      -> putOutputable arrowTp
    space
    putType funTp
  GHC.HsAppTy _ t1 t2 ->
    putType t1 >> space >> putType t2
  GHC.HsExplicitListTy _ _ xs -> do
    putText "'["
    sep
      (comma >> space)
      (fmap putType xs)
    putText "]"
  GHC.HsExplicitTupleTy _ xs -> do
    putText "'("
    sep
      (comma >> space)
      (fmap putType xs)
    putText ")"
  GHC.HsOpTy _ lhs op rhs -> do
    putType lhs
    space
    putRdrName op
    space
    putType rhs
  GHC.HsTyVar _ flag rdrName -> do
    case flag of
      GHC.IsPromoted  -> putText "'"
      GHC.NotPromoted -> pure ()
    putRdrName rdrName
  GHC.HsTyLit _ tp ->
    putOutputable tp
  GHC.HsParTy _ tp -> do
    putText "("
    putType tp
    putText ")"
  GHC.HsTupleTy _ _ xs -> do
    putText "("
    sep
      (comma >> space)
      (fmap putType xs)
    putText ")"
  GHC.HsForAllTy {} ->
    putOutputable ltp
  GHC.HsQualTy {} ->
    putOutputable ltp
  GHC.HsAppKindTy _ _ _ ->
    putOutputable ltp
  GHC.HsListTy _ _ ->
    putOutputable ltp
  GHC.HsSumTy _ _ ->
    putOutputable ltp
  GHC.HsIParamTy _ _ _ ->
    putOutputable ltp
  GHC.HsKindSig _ _ _ ->
    putOutputable ltp
  GHC.HsStarTy _ _ ->
    putOutputable ltp
  GHC.HsSpliceTy _ _ ->
    putOutputable ltp
  GHC.HsDocTy _ _ _ ->
    putOutputable ltp
  GHC.HsBangTy _ _ _ ->
    putOutputable ltp
  GHC.HsRecTy _ _ ->
    putOutputable ltp
  GHC.HsWildCardTy _ ->
    putOutputable ltp
  GHC.XHsType _ ->
    putOutputable ltp

-- | Get a docstring on the start line of 'SrcSpan' that is a @-- ^@ comment
{-
getDocstrPrev :: SrcSpan -> P (Maybe GHC.EpaComment)
getDocstrPrev = \case
  UnhelpfulSpan _ -> pure Nothing
  RealSrcSpan rspan -> do
    removeComment \case
      L rloc epaComment | GHC.EpaLineComment s <- GHC.ac_tok epaComment ->
        and
          [ srcSpanStartLine rspan == srcSpanStartLine rloc
          , "-- ^" `isPrefixOf` s
          ]
      _ -> False
-}

-- | Print a newline
newline :: P ()
newline = do
  l <- gets currentLine
  modify \s -> s { currentLine = "", linePos = 0, lines = lines s <> [l] }

-- | Print a space
space :: P ()
space = putText " "

-- | Print a number of spaces
spaces :: Int -> P ()
spaces i = replicateM_ i space

-- | Print a dot
dot :: P ()
dot = putText "."

-- | Print a comma
comma :: P ()
comma = putText ","

-- | Add parens around a printed action
parenthesize :: P a -> P a
parenthesize action = putText "(" *> action <* putText ")"

-- | Add separator between each element of the given printers
sep :: P a -> [P a] -> P ()
sep _ []             = pure ()
sep s (first : rest) = first >> forM_ rest ((>>) s)

-- | Prefix a printer with another one
prefix :: P a -> P b -> P b
prefix pa pb = pa >> pb

-- | Suffix a printer with another one
suffix :: P a -> P b -> P a
suffix pa pb = pb >> pa

-- | Indent to a given number of spaces.  If the current line already exceeds
-- that number in length, nothing happens.
pad :: Int -> P ()
pad n = do
    len <- length <$> getCurrentLine
    spaces $ n - len

{-
-- | Gets comment on supplied 'line' and removes it from the state
removeLineComment :: Int -> P (Maybe GHC.EpaComment)
removeLineComment line =
  removeComment (\(L rloc _) -> srcSpanStartLine rloc == line)

-- | Removes comments from the state up to start line of 'SrcSpan' and returns
--   the ones that were removed
removeCommentTo :: SrcSpan -> P [GHC.EpaComment]
removeCommentTo = \case
  UnhelpfulSpan _ -> pure []
  RealSrcSpan rspan -> removeCommentTo' (srcSpanStartLine rspan)

-- | Removes comments from the state up to end line of 'SrcSpan' and returns
--   the ones that were removed
removeCommentToEnd :: SrcSpan -> P [GHC.EpaComment]
removeCommentToEnd = \case
  UnhelpfulSpan _ -> pure []
  RealSrcSpan rspan -> removeCommentTo' (srcSpanEndLine rspan)

-- | Removes comments to the line number given and returns the ones removed
removeCommentTo' :: Int -> P [GHC.EpaComment]
removeCommentTo' line =
  removeComment (\(L rloc _) -> srcSpanStartLine rloc < line) >>= \case
    Nothing -> pure []
    Just c -> do
      rest <- removeCommentTo' line
      pure (c : rest)

-- | Removes comments from the state while given predicate 'p' is true
removeComments :: (GHC.RealLocated GHC.EpaComment -> Bool) -> P [GHC.EpaComment]
removeComments p =
  removeComment p >>= \case
    Just c -> do
      rest <- removeComments p
      pure (c : rest)
    Nothing -> pure []

-- | Remove a comment from the state given predicate 'p'
removeComment :: (GHC.RealLocated GHC.EpaComment -> Bool) -> P (Maybe GHC.EpaComment)
removeComment p = do
  comments <- gets pendingComments

  let
    foundComment =
      find p comments

    newPendingComments =
      maybe comments (`delete` comments) foundComment

  modify \s -> s { pendingComments = newPendingComments }
  pure $ fmap (\(L _ c) -> c) foundComment
-}

-- | Get current line
getCurrentLine :: P String
getCurrentLine = gets currentLine

-- | Get current line length
getCurrentLineLength :: P Int
getCurrentLineLength = fmap length getCurrentLine

-- | Peek at the next comment in the state
{-
peekNextCommentPos :: P (Maybe SrcSpan)
peekNextCommentPos = do
  gets pendingComments <&> \case
    (L next _ : _) -> Just (RealSrcSpan next)
    [] -> Nothing
-}

-- | Get attached comments belonging to '[Located a]' given
{-
groupAttachedComments :: [Located a] -> P [([GHC.EpaComment], NonEmpty (Located a))]
groupAttachedComments = go
  where
    go :: [Located a] -> P [([GHC.EpaComment], NonEmpty (Located a))]
    go (L rspan x : xs) = do
      comments <- removeCommentTo rspan
      nextGroupStartM <- peekNextCommentPos

      let
        sameGroupOf = maybe xs \nextGroupStart ->
          takeWhile (\(L p _)-> p < nextGroupStart) xs

        restOf = maybe [] \nextGroupStart ->
          dropWhile (\(L p _) -> p <= nextGroupStart) xs

      restGroups <- go (restOf nextGroupStartM)
      pure $ (comments, L rspan x :| sameGroupOf nextGroupStartM) : restGroups

    go _ = pure []

-- | A view on 'groupAttachedComments': return 'Just' when there is just a
--   one big group without any comments.
groupWithoutComments
    :: [([GHC.EpaComment], NonEmpty (Located a))]
    -> Maybe [Located a]
groupWithoutComments grouped
    | all (null . fst) grouped
    = Just $ concatMap (toList . snd) grouped
    | otherwise
    = Nothing
-}

modifyCurrentLine :: (String -> String) -> P ()
modifyCurrentLine f = do
    s0 <- get
    put s0 {currentLine = f $ currentLine s0}

wrapping
    :: P a  -- ^ First printer to run
    -> P a  -- ^ Printer to run if first printer violates max columns
    -> P a  -- ^ Result of either the first or the second printer
wrapping p1 p2 = do
    maxCols <- asks columns
    case maxCols of
        -- No wrapping
        Nothing -> p1
        Just c  -> do
            s0 <- get
            x <- p1
            s1 <- get
            if length (currentLine s1) <= c
                -- No need to wrap
                then pure x
                else do
                    put s0
                    y <- p2
                    s2 <- get
                    if length (currentLine s1) == length (currentLine s2)
                        -- Wrapping didn't help!
                        then put s1 >> pure x
                        -- Wrapped
                        else pure y

withColumns :: Maybe Int -> P a -> P a
withColumns c = local $ \pc -> pc {columns = c}
