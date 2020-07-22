--------------------------------------------------------------------------------
module Language.Haskell.Stylish.Util
    ( nameToString
    , isOperator
    , indent
    , padRight
    , everything
    , infoPoints
    , trimLeft
    , trimRight
    , wrap
    , wrapRest
    , wrapMaybe
    , wrapRestMaybe

    , withHead
    , withInit
    , withTail
    , withLast

    , toRealSrcSpan

    , traceOutputtable
    , traceOutputtableM

    , unguardedRhsBody

    , getConDecls
    , getConDeclDetails
    , getLocRecs
    ) where


--------------------------------------------------------------------------------
import           Control.Arrow                 ((&&&), (>>>))
import           Data.Char                     (isAlpha, isSpace)
import           Data.Data                     (Data)
import qualified Data.Generics                 as G
import           Data.Maybe                    (fromMaybe, listToMaybe,
                                                maybeToList)
import           Data.Typeable                 (cast)
import           Debug.Trace                   (trace)
import qualified Language.Haskell.Exts         as H
import qualified Outputable
import qualified OccName                       as O
import qualified GHC.Hs                        as Hs
import qualified SrcLoc                        as S


--------------------------------------------------------------------------------
import           Language.Haskell.Stylish.Step


--------------------------------------------------------------------------------
nameToString :: H.Name l -> String
nameToString (H.Ident _ str)  = str
nameToString (H.Symbol _ str) = str

-- MAYBE use Name
nameToString' :: O.OccName -> String 
nameToString' = O.occNameString

--------------------------------------------------------------------------------
isOperator :: H.Name l -> Bool
isOperator = fromMaybe False
    . (fmap (not . isAlpha) . listToMaybe)
    . nameToString

isOperator' :: O.OccName -> Bool
isOperator' = O.isSymOcc

--------------------------------------------------------------------------------
indent :: Int -> String -> String
indent len = (indentPrefix len ++)


--------------------------------------------------------------------------------
indentPrefix :: Int -> String
indentPrefix = (`replicate` ' ')


--------------------------------------------------------------------------------
padRight :: Int -> String -> String
padRight len str = str ++ replicate (len - length str) ' '


--------------------------------------------------------------------------------
everything :: (Data a, Data b) => a -> [b]
everything = G.everything (++) (maybeToList . cast)


--------------------------------------------------------------------------------
infoPoints :: H.SrcSpanInfo -> [((Int, Int), (Int, Int))]
infoPoints = H.srcInfoPoints >>> map (H.srcSpanStart &&& H.srcSpanEnd)

-- Info about just a RealSrcSpan
infoRealSrcSpan :: S.RealSrcSpan -> ((Int,Int),(Int,Int))
infoRealSrcSpan src = ((startLine, startCol),(endLine, endCol))
  where
    startLine = S.srcSpanStartLine src
    startCol  = S.srcSpanStartCol  src
    endLine   = S.srcSpanEndLine   src
    endCol    = S.srcSpanEndCol    src


--------------------------------------------------------------------------------
trimLeft :: String -> String
trimLeft  = dropWhile isSpace


--------------------------------------------------------------------------------
trimRight :: String -> String
trimRight = reverse . trimLeft . reverse


--------------------------------------------------------------------------------
wrap :: Int       -- ^ Maximum line width
     -> String    -- ^ Leading string
     -> Int       -- ^ Indentation
     -> [String]  -- ^ Strings to add/wrap
     -> Lines     -- ^ Resulting lines
wrap maxWidth leading ind = wrap' leading
  where
    wrap' ss [] = [ss]
    wrap' ss (str:strs)
        | overflows ss str =
            ss : wrapRest maxWidth ind (str:strs)
        | otherwise = wrap' (ss ++ " " ++ str) strs

    overflows ss str = length ss > maxWidth ||
        ((length ss + length str) >= maxWidth && ind + length str  <= maxWidth)


--------------------------------------------------------------------------------
wrapMaybe :: Maybe Int -- ^ Maximum line width (maybe)
          -> String    -- ^ Leading string
          -> Int       -- ^ Indentation
          -> [String]  -- ^ Strings to add/wrap
          -> Lines     -- ^ Resulting lines
wrapMaybe (Just maxWidth) = wrap maxWidth
wrapMaybe Nothing         = noWrap


--------------------------------------------------------------------------------
noWrap :: String    -- ^ Leading string
       -> Int       -- ^ Indentation
       -> [String]  -- ^ Strings to add
       -> Lines     -- ^ Resulting lines
noWrap leading _ind = noWrap' leading
  where
    noWrap' ss []         = [ss]
    noWrap' ss (str:strs) = noWrap' (ss ++ " " ++ str) strs


--------------------------------------------------------------------------------
wrapRest :: Int
         -> Int
         -> [String]
         -> Lines
wrapRest maxWidth ind = reverse . wrapRest' [] ""
  where
    wrapRest' ls ss []
        | null ss = ls
        | otherwise = ss:ls
    wrapRest' ls ss (str:strs)
        | null ss = wrapRest' ls (indent ind str) strs
        | overflows ss str = wrapRest' (ss:ls) "" (str:strs)
        | otherwise = wrapRest' ls (ss ++ " " ++ str) strs

    overflows ss str = (length ss + length str + 1) >= maxWidth


--------------------------------------------------------------------------------
wrapRestMaybe :: Maybe Int
              -> Int
              -> [String]
              -> Lines
wrapRestMaybe (Just maxWidth) = wrapRest maxWidth
wrapRestMaybe Nothing         = noWrapRest


--------------------------------------------------------------------------------
noWrapRest :: Int
           -> [String]
           -> Lines
noWrapRest ind = reverse . noWrapRest' [] ""
  where
    noWrapRest' ls ss []
        | null ss = ls
        | otherwise = ss:ls
    noWrapRest' ls ss (str:strs)
        | null ss = noWrapRest' ls (indent ind str) strs
        | otherwise = noWrapRest' ls (ss ++ " " ++ str) strs


--------------------------------------------------------------------------------
withHead :: (a -> a) -> [a] -> [a]
withHead _ []       = []
withHead f (x : xs) = f x : xs


--------------------------------------------------------------------------------
withLast :: (a -> a) -> [a] -> [a]
withLast _ []       = []
withLast f [x]      = [f x]
withLast f (x : xs) = x : withLast f xs


--------------------------------------------------------------------------------
withInit :: (a -> a) -> [a] -> [a]
withInit _ []       = []
withInit _ [x]      = [x]
withInit f (x : xs) = f x : withInit f xs

--------------------------------------------------------------------------------
withTail :: (a -> a) -> [a] -> [a]
withTail _ []       = []
withTail f (x : xs) = x : map f xs


--------------------------------------------------------------------------------
traceOutputtable :: Outputable.Outputable a => String -> a -> b -> b
traceOutputtable title x =
    trace (title ++ ": " ++ (Outputable.showSDocUnsafe $ Outputable.ppr x))


--------------------------------------------------------------------------------
traceOutputtableM :: (Outputable.Outputable a, Monad m) => String -> a -> m ()
traceOutputtableM title x = traceOutputtable title x $ pure ()


--------------------------------------------------------------------------------
-- take the (Maybe) RealSrcSpan out of the SrcSpan
toRealSrcSpan :: S.SrcSpan -> Maybe S.RealSrcSpan
toRealSrcSpan (S.RealSrcSpan s) = Just s
toRealSrcSpan _                 = Nothing


--------------------------------------------------------------------------------
-- Utility: grab the body out of guarded RHSs if it's a single unguarded one.
unguardedRhsBody :: Hs.GRHSs Hs.GhcPs a -> Maybe a
unguardedRhsBody (Hs.GRHSs _ [grhs] _)
    | Hs.GRHS _ [] body <- S.unLoc grhs = Just body
unguardedRhsBody _ = Nothing


--------------------------------------------------------------------------------
-- get a list of un-located constructors
getConDecls :: Hs.HsDataDefn Hs.GhcPs -> [Hs.ConDecl Hs.GhcPs]
getConDecls d@(Hs.HsDataDefn _ _ _ _ _ cons _) = 
  map S.unLoc $ Hs.dd_cons d
getConDecls (Hs.XHsDataDefn x) = Hs.noExtCon x


--------------------------------------------------------------------------------
-- get Arguments from data Construction Declaration
getConDeclDetails :: Hs.ConDecl Hs.GhcPs -> Hs.HsConDeclDetails Hs.GhcPs
getConDeclDetails d@(Hs.ConDeclGADT _ _ _ _ _ _ _ _) = Hs.con_args d
getConDeclDetails d@(Hs.ConDeclH98 _ _ _ _ _ _ _)    = Hs.con_args d
getConDeclDetails (Hs.XConDecl x)                    = Hs.noExtCon x


--------------------------------------------------------------------------------
-- look for Record(s) in a list of Construction Declaration details
getLocRecs :: [Hs.HsConDeclDetails Hs.GhcPs] -> [S.Located [Hs.LConDeclField Hs.GhcPs]]
getLocRecs conDeclDetails =
  [ rec | Hs.RecCon rec <- conDeclDetails ]
