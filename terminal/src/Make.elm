module Make exposing
    ( Flags(..)
    , Output(..)
    , ReportType(..)
    , docsFile
    , output
    , parseOutput
    , parseReportType
    , reportType
    , run
    )

import AST.Optimized as Opt
import BackgroundWriter as BW
import Build
import Data.IO as IO exposing (IO)
import Data.NonEmptyList as NE
import Elm.Details as Details
import Elm.ModuleName as ModuleName
import File
import Generate
import Generate.Html as Html
import Json.Decode as Decode
import Json.Encode as Encode
import Maybe.Extra as Maybe
import Reporting
import Reporting.Exit as Exit
import Reporting.Task as Task
import Stuff
import Terminal.Internal exposing (Parser(..))
import Utils.Main as Utils exposing (FilePath)



-- FLAGS


type Flags
    = Flags Bool Bool (Maybe Output) (Maybe ReportType) (Maybe String)


type Output
    = JS String
    | Html String
    | DevNull


type ReportType
    = Json



-- RUN


type alias Task a =
    Task.Task Exit.Make a


run : List String -> Flags -> IO ()
run paths ((Flags _ _ _ report _) as flags) =
    getStyle report
        |> IO.bind
            (\style ->
                Stuff.findRoot
                    |> IO.bind
                        (\maybeRoot ->
                            Reporting.attemptWithStyle style Exit.makeToReport <|
                                case maybeRoot of
                                    Just root ->
                                        runHelp root paths style flags

                                    Nothing ->
                                        IO.pure (Err Exit.MakeNoOutline)
                        )
            )


runHelp : String -> List String -> Reporting.Style -> Flags -> IO (Result Exit.Make ())
runHelp root paths style (Flags debug optimize maybeOutput _ maybeDocs) =
    BW.withScope
        (\scope ->
            Stuff.withRootLock root <|
                Task.run <|
                    (getMode debug optimize
                        |> Task.bind
                            (\desiredMode ->
                                Task.eio Exit.MakeBadDetails (Details.load style scope root)
                                    |> Task.bind
                                        (\details ->
                                            case paths of
                                                [] ->
                                                    getExposed details
                                                        |> Task.bind (\exposed -> buildExposed style root details maybeDocs exposed)

                                                p :: ps ->
                                                    buildPaths style root details (NE.Nonempty p ps)
                                                        |> Task.bind
                                                            (\artifacts ->
                                                                case maybeOutput of
                                                                    Nothing ->
                                                                        case getMains artifacts of
                                                                            [] ->
                                                                                Task.pure ()

                                                                            [ name ] ->
                                                                                toBuilder root details desiredMode artifacts
                                                                                    |> Task.bind
                                                                                        (\builder ->
                                                                                            generate style "index.html" (Html.sandwich name builder) (NE.Nonempty name [])
                                                                                        )

                                                                            name :: names ->
                                                                                toBuilder root details desiredMode artifacts
                                                                                    |> Task.bind
                                                                                        (\builder ->
                                                                                            generate style "elm.js" builder (NE.Nonempty name names)
                                                                                        )

                                                                    Just DevNull ->
                                                                        Task.pure ()

                                                                    Just (JS target) ->
                                                                        case getNoMains artifacts of
                                                                            [] ->
                                                                                toBuilder root details desiredMode artifacts
                                                                                    |> Task.bind
                                                                                        (\builder ->
                                                                                            generate style target builder (Build.getRootNames artifacts)
                                                                                        )

                                                                            name :: names ->
                                                                                Task.throw (Exit.MakeNonMainFilesIntoJavaScript name names)

                                                                    Just (Html target) ->
                                                                        hasOneMain artifacts
                                                                            |> Task.bind
                                                                                (\name ->
                                                                                    toBuilder root details desiredMode artifacts
                                                                                        |> Task.bind
                                                                                            (\builder ->
                                                                                                generate style target (Html.sandwich name builder) (NE.Nonempty name [])
                                                                                            )
                                                                                )
                                                            )
                                        )
                            )
                    )
        )



-- GET INFORMATION


getStyle : Maybe ReportType -> IO Reporting.Style
getStyle report =
    case report of
        Nothing ->
            Reporting.terminal

        Just Json ->
            IO.pure Reporting.json


getMode : Bool -> Bool -> Task DesiredMode
getMode debug optimize =
    case ( debug, optimize ) of
        ( True, True ) ->
            Task.throw Exit.MakeCannotOptimizeAndDebug

        ( True, False ) ->
            Task.pure Debug

        ( False, False ) ->
            Task.pure Dev

        ( False, True ) ->
            Task.pure Prod


getExposed : Details.Details -> Task (NE.Nonempty ModuleName.Raw)
getExposed (Details.Details _ validOutline _ _ _ _) =
    case validOutline of
        Details.ValidApp _ ->
            Task.throw Exit.MakeAppNeedsFileNames

        Details.ValidPkg _ exposed _ ->
            case exposed of
                [] ->
                    Task.throw Exit.MakePkgNeedsExposing

                m :: ms ->
                    Task.pure (NE.Nonempty m ms)



-- BUILD PROJECTS


buildExposed : Reporting.Style -> FilePath -> Details.Details -> Maybe FilePath -> NE.Nonempty ModuleName.Raw -> Task ()
buildExposed style root details maybeDocs exposed =
    let
        docsGoal =
            Utils.maybe Build.IgnoreDocs Build.WriteDocs maybeDocs
    in
    Task.eio Exit.MakeCannotBuild <|
        Build.fromExposed (Decode.succeed ()) (\_ -> Encode.object []) style root details docsGoal exposed


buildPaths : Reporting.Style -> FilePath -> Details.Details -> NE.Nonempty FilePath -> Task Build.Artifacts
buildPaths style root details paths =
    Task.eio Exit.MakeCannotBuild <|
        Build.fromPaths style root details paths



-- GET MAINS


getMains : Build.Artifacts -> List ModuleName.Raw
getMains (Build.Artifacts _ _ roots modules) =
    List.filterMap (getMain modules) (NE.toList roots)


getMain : List Build.Module -> Build.Root -> Maybe ModuleName.Raw
getMain modules root =
    case root of
        Build.Inside name ->
            if List.any (isMain name) modules then
                Just name

            else
                Nothing

        Build.Outside name _ (Opt.LocalGraph maybeMain _ _) ->
            maybeMain
                |> Maybe.map (\_ -> name)


isMain : ModuleName.Raw -> Build.Module -> Bool
isMain targetName modul =
    case modul of
        Build.Fresh name _ (Opt.LocalGraph maybeMain _ _) ->
            Maybe.isJust maybeMain && name == targetName

        Build.Cached name mainIsDefined _ ->
            mainIsDefined && name == targetName



-- HAS ONE MAIN


hasOneMain : Build.Artifacts -> Task ModuleName.Raw
hasOneMain (Build.Artifacts _ _ roots modules) =
    case roots of
        NE.Nonempty root [] ->
            Task.mio Exit.MakeNoMain (IO.pure <| getMain modules root)

        NE.Nonempty _ (_ :: _) ->
            Task.throw Exit.MakeMultipleFilesIntoHtml



-- GET MAINLESS


getNoMains : Build.Artifacts -> List ModuleName.Raw
getNoMains (Build.Artifacts _ _ roots modules) =
    List.filterMap (getNoMain modules) (NE.toList roots)


getNoMain : List Build.Module -> Build.Root -> Maybe ModuleName.Raw
getNoMain modules root =
    case root of
        Build.Inside name ->
            if List.any (isMain name) modules then
                Nothing

            else
                Just name

        Build.Outside name _ (Opt.LocalGraph maybeMain _ _) ->
            case maybeMain of
                Just _ ->
                    Nothing

                Nothing ->
                    Just name



-- GENERATE


generate : Reporting.Style -> FilePath -> String -> NE.Nonempty ModuleName.Raw -> Task ()
generate style target builder names =
    Task.io
        (Utils.dirCreateDirectoryIfMissing True (Utils.fpTakeDirectory target)
            |> IO.bind (\_ -> File.writeBuilder target builder)
            |> IO.bind (\_ -> Reporting.reportGenerate style names target)
        )



-- TO BUILDER


type DesiredMode
    = Debug
    | Dev
    | Prod


toBuilder : FilePath -> Details.Details -> DesiredMode -> Build.Artifacts -> Task String
toBuilder root details desiredMode artifacts =
    Task.mapError Exit.MakeBadGenerate <|
        case desiredMode of
            Debug ->
                Generate.debug root details artifacts

            Dev ->
                Generate.dev root details artifacts

            Prod ->
                Generate.prod root details artifacts



-- PARSERS


reportType : Parser ReportType
reportType =
    Parser
        "report type"
        "report types"
        parseReportType
        (\_ -> IO.pure [ "json" ])
        (\_ -> IO.pure [ "json" ])


parseReportType : String -> Maybe ReportType
parseReportType string =
    if string == "json" then
        Just Json

    else
        Nothing


output : Parser Output
output =
    Parser
        "output file"
        "output files"
        parseOutput
        (\_ -> IO.pure [])
        (\_ -> IO.pure [ "elm.js", "index.html", "/dev/null" ])


parseOutput : String -> Maybe Output
parseOutput name =
    if isDevNull name then
        Just DevNull

    else if hasExt ".html" name then
        Just (Html name)

    else if hasExt ".js" name then
        Just (JS name)

    else
        Nothing


docsFile : Parser FilePath
docsFile =
    Parser
        "json file"
        "json files"
        (\name ->
            if hasExt ".json" name then
                Just name

            else
                Nothing
        )
        (\_ -> IO.pure [])
        (\_ -> IO.pure [ "docs.json", "documentation.json" ])


hasExt : String -> String -> Bool
hasExt ext path =
    Utils.fpTakeExtension path == ext && String.length path > String.length ext


isDevNull : String -> Bool
isDevNull name =
    name == "/dev/null" || name == "NUL" || name == "<|null"
