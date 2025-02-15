module Terminal exposing
    ( app
    , args
    , exactly
    , flag
    , flags
    , more
    , noArgs
    , noFlags
    , onOff
    , oneOf
    , oneOrMore
    , optional
    , require0
    , require1
    , require2
    , require3
    , require4
    , require5
    , required
    , zeroOrMore
    )

import Data.IO as IO exposing (IO)
import Elm.Version as V
import List.Extra as List
import Reporting.Doc as D
import Terminal.Chomp as Chomp
import Terminal.Error as Error
import Terminal.Internal exposing (Args(..), Command(..), CompleteArgs(..), Flag(..), Flags(..), Parser(..), RequiredArgs(..), Summary(..), toName)
import Utils.Main as Utils exposing (FilePath)



-- APP


app : D.Doc -> D.Doc -> List Command -> IO ()
app intro outro commands =
    Utils.envGetArgs
        |> IO.bind
            (\argStrings ->
                case argStrings of
                    [] ->
                        Error.exitWithOverview intro outro commands

                    [ "--help" ] ->
                        Error.exitWithOverview intro outro commands

                    [ "--version" ] ->
                        IO.hPutStrLn IO.stdout (V.toChars V.compiler)
                            |> IO.bind (\_ -> Utils.exitSuccess)

                    command :: chunks ->
                        case List.find (\cmd -> toName cmd == command) commands of
                            Nothing ->
                                Error.exitWithUnknown command (List.map toName commands)

                            Just (Command _ _ details example argDocs flagDocs callback) ->
                                if List.member "--help" chunks then
                                    Error.exitWithHelp (Just command) details example argDocs flagDocs

                                else
                                    case callback chunks of
                                        Ok res ->
                                            res

                                        Err err ->
                                            Error.exitWithError err
            )



-- AUTO-COMPLETE


getCompIndex : String -> IO ( Int, List String )
getCompIndex line =
    Utils.envLookupEnv "COMP_POINT"
        |> IO.bind
            (\maybePoint ->
                case Maybe.andThen String.toInt maybePoint of
                    Nothing ->
                        let
                            chunks =
                                String.words line
                        in
                        IO.pure ( List.length chunks, chunks )

                    Just point ->
                        let
                            lineChars =
                                String.toList line

                            lineIndexes =
                                List.repeat (String.length line) ()
                                    |> List.indexedMap (\i _ -> i)

                            groups =
                                Utils.listGroupBy grouper
                                    (List.zip lineChars lineIndexes)

                            rawChunks =
                                List.drop 1 (List.filter (List.all (not << isSpace << Tuple.first)) groups)
                        in
                        IO.pure
                            ( findIndex 1 point rawChunks
                            , List.map (String.fromList << List.map Tuple.first) rawChunks
                            )
            )


grouper : ( Char, Int ) -> ( Char, Int ) -> Bool
grouper ( c1, _ ) ( c2, _ ) =
    isSpace c1 == isSpace c2


isSpace : Char -> Bool
isSpace char =
    char == ' ' || char == '\t' || char == '\n'


findIndex : Int -> Int -> List (List ( Char, Int )) -> Int
findIndex index point chunks =
    case chunks of
        [] ->
            index

        chunk :: cs ->
            let
                lo =
                    Tuple.second (Utils.head chunk)

                hi =
                    Tuple.second (Utils.last chunk)
            in
            if point < lo then
                0

            else if point <= hi + 1 then
                index

            else
                findIndex (index + 1) point cs



-- FLAGS


{-| -}
noFlags : Flags ()
noFlags =
    FDone ()


{-| -}
flags : a -> Flags a
flags =
    FDone


{-| -}
more : Flag a -> Flags (a -> b) -> Flags b
more =
    -- FMore
    Debug.todo "more"



-- FLAG


{-| -}
flag : String -> Parser a -> String -> Flag (Maybe a)
flag =
    -- Flag
    Debug.todo "flag"


{-| -}
onOff : String -> String -> Flag Bool
onOff =
    OnOff



-- FANCY ARGS


{-| -}
args : a -> RequiredArgs a
args =
    Done


exactly : RequiredArgs a -> Args a
exactly requiredArgs =
    Args [ Exactly requiredArgs ]


exclamantionMark : RequiredArgs (a -> b) -> Parser a -> RequiredArgs b
exclamantionMark =
    -- Required
    Debug.todo "exclamantionMark"


questionMark : RequiredArgs (Maybe a -> b) -> Parser a -> Args b
questionMark requiredArgs optionalArg =
    -- Args [ Optional requiredArgs optionalArg ]
    Debug.todo "questionMark"


dotdotdot : RequiredArgs (List a -> b) -> Parser a -> Args b
dotdotdot requiredArgs repeatedArg =
    -- Args [ Multiple requiredArgs repeatedArg ]
    Debug.todo "dotdotdot"


oneOf : List (Args a) -> Args a
oneOf listOfArgs =
    Args (List.concatMap (\(Args a) -> a) listOfArgs)



-- SIMPLE ARGS


noArgs : Args ()
noArgs =
    exactly (args ())


required : Parser a -> Args a
required parser =
    require1 identity parser


optional : Parser a -> Args (Maybe a)
optional parser =
    questionMark (args identity) parser


zeroOrMore : Parser a -> Args (List a)
zeroOrMore parser =
    dotdotdot (args identity) parser


oneOrMore : Parser a -> Args ( a, List a )
oneOrMore parser =
    -- exclamantionMark (args Tuple.pair) (dotdotdot parser parser)
    Debug.todo "oneOrMore"


require0 : args -> Args args
require0 value =
    exactly (args value)


require1 : (a -> args) -> Parser a -> Args args
require1 func a =
    exactly (exclamantionMark (args func) a)


require2 : (a -> b -> args) -> Parser a -> Parser b -> Args args
require2 func a b =
    exactly (exclamantionMark (exclamantionMark (args func) a) b)


require3 : (a -> b -> c -> args) -> Parser a -> Parser b -> Parser c -> Args args
require3 func a b c =
    exactly (exclamantionMark (exclamantionMark (exclamantionMark (args func) a) b) c)


require4 : (a -> b -> c -> d -> args) -> Parser a -> Parser b -> Parser c -> Parser d -> Args args
require4 func a b c d =
    exactly (exclamantionMark (exclamantionMark (exclamantionMark (exclamantionMark (args func) a) b) c) d)


require5 : (a -> b -> c -> d -> e -> args) -> Parser a -> Parser b -> Parser c -> Parser d -> Parser e -> Args args
require5 func a b c d e =
    exactly (exclamantionMark (exclamantionMark (exclamantionMark (exclamantionMark (exclamantionMark (args func) a) b) c) d) e)



-- SUGGEST FILES


{-| Helper for creating custom `Parser` values. It will suggest directories and
file names:

    suggestFiles [] -- suggests any file

    suggestFiles [ "elm" ] -- suggests only .elm files

    suggestFiles [ "js", "html" ] -- suggests only .js and .html files

Notice that you can limit the suggestion by the file extension! If you need
something more elaborate, you can implement a function like this yourself that
does whatever you need!

-}
suggestFiles_ : List String -> String -> IO (List String)
suggestFiles_ extensions string =
    let
        ( dir, start ) =
            Utils.fpSplitFileName string
    in
    Utils.dirGetDirectoryContents dir
        |> IO.bind
            (\content ->
                -- IO.bind Maybe.catMaybes
                --     (traverse (isPossibleSuggestion extensions start dir) content)
                Debug.todo "suggestFiles_"
            )


isPossibleSuggestion : List String -> String -> FilePath -> FilePath -> IO (Maybe FilePath)
isPossibleSuggestion extensions start dir path =
    if String.startsWith start path then
        Utils.dirDoesDirectoryExist (Utils.fpForwardSlash dir path)
            |> IO.fmap
                (\isDir ->
                    if isDir then
                        Just (path ++ "/")

                    else if isOkayExtension path extensions then
                        Just path

                    else
                        Nothing
                )

    else
        IO.pure Nothing


isOkayExtension : FilePath -> List String -> Bool
isOkayExtension path extensions =
    List.isEmpty extensions || List.member (Utils.fpTakeExtension path) extensions
