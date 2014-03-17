module System.Console.HsOptions(
    make,
    get,

    intParser,
    stringParser,
    boolParser,

    boolFlag,

    flagToData,
    combine,
    process,
    showHelp,

    isOptional,
    emptyValueIs,
    defaultIs,
    parser,
    maybeParser,

    Flag(..),
    FlagData,
    FlagError(..),
    FlagResults,
    ProcessResults,
    ArgsResults,
    FlagDataConf(..),
    FlagConf(..)
) where

import Data.List
import Data.Maybe
import Text.Read(readMaybe)
import qualified Data.Map as Map

data Flag a = Flag String String [FlagConf a]
data FlagError = FlagNonFatalError String | FlagFatalError String deriving (Show)
type FlagData = (Map.Map String FlagDataAtom)
type FlagDataAtom = (String, [FlagDataConf])
type FlagResults = (Map.Map String FlagArgument)
type ArgsResults = [String]
type ParseResults  = (FlagResults, ArgsResults)
type ProcessResults  = (FlagResults, ArgsResults)
type PipelineFunction = (FlagData -> FlagResults -> ([FlagError], FlagResults))
data FlagArgument = FlagMissing String 
                  | FlagValueMissing String
                  | FlagValue String String

data ValidationResult = ValidationError FlagError
                      | ValidationSuccess 


data FlagConf a = 
    FlagConf_IsOptional 
  | FlagConf_DefaultIs a
  | FlagConf_Parser (FlagArgument -> Maybe a)
  | FlagConf_EmptyValueIs a

data FlagDataConf = 
    FlagDataConf_IsOptional
  | FlagDataConf_HasDefault 
  | FlagDataConf_Validator (FlagArgument -> Bool) 
  | FlagDataConf_HasEmptyValue

isOptional :: FlagConf (Maybe a)
isOptional = FlagConf_IsOptional

emptyValueIs :: a -> FlagConf a
emptyValueIs = FlagConf_EmptyValueIs

defaultIs :: a -> FlagConf a
defaultIs = FlagConf_DefaultIs 

parser :: (FlagArgument -> Maybe a) -> FlagConf a
parser = FlagConf_Parser 

maybeParser :: (FlagArgument -> Maybe a) -> FlagConf (Maybe a)
maybeParser p =  FlagConf_Parser p'
  where p' = maybeParserWrapper p

maybeParserWrapper :: (FlagArgument -> Maybe a) -> FlagArgument -> Maybe (Maybe a)
maybeParserWrapper _p (FlagMissing _) = Just Nothing
maybeParserWrapper _p (FlagValueMissing _) = Just Nothing
maybeParserWrapper p flagValue = case p flagValue of
                                    Nothing -> Nothing
                                    justSomething -> Just justSomething


emptyFlagResults :: Map.Map String FlagArgument
emptyFlagResults = Map.empty

emptyArgsResults :: [String]
emptyArgsResults = []

isInteger :: String -> Bool
isInteger s = case reads s :: [(Integer, String)] of
                [(_, "")] -> True
                _         -> False

isDouble :: String -> Bool
isDouble s = case reads s :: [(Double, String)] of
                [(_, "")] -> True
                _         -> False

isNumeric :: String -> Bool
isNumeric s = isInteger s || isDouble s

get :: FlagResults -> Flag a ->  a
get result (Flag name _ flagconf) = fromJust $ runParser flagconf argValue
    where argValue = fromMaybe (error ("Error while trying to get flag value for '" ++ name ++ "'." ++
                                       " Perhaps this flag was not added to the flagData array"))
                               (Map.lookup name result )

runParser :: [FlagConf a] -> FlagArgument -> Maybe a
runParser flagconf = p
  where p = head [x | (FlagConf_Parser x) <- flagconf]

combine :: [FlagData] -> FlagData
combine = foldl Map.union Map.empty

flagToData :: Flag a -> FlagData
flagToData (Flag name help flagConf) = Map.fromList [(name, (help, flagDataConf))]
  where flagDataConf = map aux flagConf
        aux FlagConf_IsOptional = FlagDataConf_IsOptional
        aux (FlagConf_DefaultIs _) = FlagDataConf_HasDefault
        aux (FlagConf_EmptyValueIs _) = FlagDataConf_HasEmptyValue
        aux (FlagConf_Parser p) = FlagDataConf_Validator (isJust . p)

isFlagName :: String -> Bool
isFlagName "-" = False
isFlagName "--" = False
isFlagName name 
  | take 2 name == "--" = True
  | take 1 name == "-" && (not . isNumeric) (drop 1 name) = True
  | otherwise = False

getFlagName :: String -> String
getFlagName name 
  | take 2 name == "--" = drop 2 name
  | otherwise = drop 1 name

makeFlagResults :: (String, FlagArgument) -> ParseResults 
makeFlagResults flagArg = (Map.fromList [flagArg], emptyArgsResults)

processFlag ::  String -> [String] -> (ParseResults, [String])
processFlag name [] = (makeFlagResults (name, FlagValueMissing name), [])
processFlag name (arg2:args)
    | isFlagName arg2 = (makeFlagResults (name, FlagValueMissing name), arg2:args)
    | otherwise = (makeFlagResults (name, FlagValue name arg2), args)

parseArg ::  String -> [String] -> (ParseResults, [String])
parseArg arg args = 
  if isFlagName arg
    then processFlag (getFlagName arg) args
    else ((emptyFlagResults, [arg]), args) 

parseArgs ::  [String] -> ParseResults -> ParseResults
parseArgs arguments res = case arguments of
    [] -> res
    arg:args -> let (res',args') = parseArg arg args in 
                parseArgs args' (merge res res')
  where merge (pr1, args1) (pr2, args2) = ( pr1 `Map.union` pr2, args1 ++ args2)
        

process :: FlagData -> [String] -> Either [FlagError] ProcessResults
process fd args = case pipeline [addMissingFlags,
                                 validateUnknownFlags,
                                 validateFlagParsers]
                             fd
                             flagResults of
    ([],res) -> Right (res, argsResults)
    (errs,_) -> Left errs
  where (flagResults, argsResults) = parseArgs args (emptyFlagResults, emptyArgsResults)

pipeline :: [PipelineFunction] -> PipelineFunction
pipeline [] _fd fr = ([], fr)
pipeline (v:vs) fd fr = case v fd fr of 
    ([], fr') -> pipeline vs fd fr' 
    (errs, fr') -> (errs, fr')

addMissingFlags :: PipelineFunction
addMissingFlags fd  fr = ([], fr `Map.union` Map.fromList flags)
  where inputFlags = Map.keys fr
        codeFlags = Map.keys fd
        missingFlags = codeFlags \\ inputFlags 
        flags = map (\ name -> (name, FlagMissing name)) missingFlags

validateUnknownFlags :: PipelineFunction
validateUnknownFlags fd fr = (errors, fr)
  where inputFlags = Map.keys fr
        codeFlags = Map.keys fd
        missingFlags = inputFlags \\ codeFlags
        errors = map flagUnkownError missingFlags
        flagUnkownError name = FlagNonFatalError $ "Error with flag --" ++
                               name ++
                               ": Unkown flag is not defined in the code"

validateFlagParsers :: PipelineFunction
validateFlagParsers fd fr = (mapMaybe aux (Map.toList fd), fr)
  where aux :: (String, FlagDataAtom) -> Maybe FlagError
        aux (name, (_, flagDataConf)) = case checkValidator flagDataConf value of
                                           ValidationError err -> Just err
                                           _ -> Nothing 
          where value = fromJust (Map.lookup name fr)

make :: (String, String, [FlagConf a]) -> Flag a
make (name, help, flagConf) = if hasParser 
                              then Flag name help flagConf
                              else error ("Flag parser was not provided for flag --'" ++ name ++ "'")
  where hasParser = not . null $ [x | (FlagConf_Parser x) <- flagConf]

showHelp :: String -> FlagData -> IO ()
showHelp desc flagData = do 
  putStrLn desc
  putStrLn ""
  putStrLn "Usage:"
  putStrLn ""
  let flags = Map.toList flagData
  mapM_ aux flags
  where aux (name, (help, _)) = putStrLn $ name ++ ":\t\t" ++ help

flagDIsOptional :: [FlagDataConf] -> Bool
flagDIsOptional fdc = not . null $ [ x | x@FlagDataConf_IsOptional <- fdc] 

flagDHasDefault :: [FlagDataConf] -> Bool
flagDHasDefault fdc = not . null $ [ x | x@FlagDataConf_HasDefault <- fdc] 

flagDHasEmptyValue :: [FlagDataConf] -> Bool
flagDHasEmptyValue fdc = not . null $ [ x | x@FlagDataConf_HasEmptyValue <- fdc] 

runDValidator :: [FlagDataConf] -> FlagArgument -> Bool
runDValidator fdc = validator 
  where validator = head [x | (FlagDataConf_Validator x) <- fdc]

validationError :: String -> String -> ValidationResult
validationError name s = ValidationError $ FlagNonFatalError ("Error with flag '--" ++name ++ "': " ++ s)

checkValidator :: [FlagDataConf] -> FlagArgument -> ValidationResult
checkValidator fdc (FlagMissing name) 
  | flagDIsOptional fdc = ValidationSuccess
  | flagDHasDefault fdc = ValidationSuccess
  | otherwise = validationError name "Flag is required"
checkValidator fdc (FlagValueMissing name) 
  | flagDHasEmptyValue fdc  = ValidationSuccess
  | otherwise = validationError name "Flag value was not provided"
checkValidator fdc flagArgument@(FlagValue name value) 
  | runDValidator fdc flagArgument = ValidationSuccess 
  | otherwise = validationError name $ "Value '" ++ value ++ "' is not valid"

{- Flag parsers -}
intParser :: FlagArgument -> Maybe Int
intParser (FlagMissing _) = Nothing
intParser (FlagValueMissing _) = Nothing
intParser (FlagValue _ value) = readMaybe value

stringParser :: FlagArgument -> Maybe String
stringParser (FlagMissing _) = Nothing
stringParser (FlagValueMissing _) = Nothing
stringParser (FlagValue _ value) = Just value

boolParser :: FlagArgument -> Maybe Bool
boolParser (FlagMissing _) = Just False
boolParser (FlagValueMissing _) = Just True
boolParser (FlagValue _ value) = readMaybe value

boolFlag :: [FlagConf Bool]
boolFlag = [parser boolParser,
            defaultIs False,
            emptyValueIs True]
