module Reporting.Exit.Help exposing
    ( Report
    , compilerReport
    , docReport
    , jsonReport
    , report
    , reportToDoc
    , reportToJson
    , toStderr
    , toStdout
    , toString
    )

import Data.IO as IO exposing (IO)
import Json.EncodeX as E
import Reporting.Doc as D
import Reporting.Error as Error
import Utils.Main as Utils



-- REPORT


type Report
    = CompilerReport String Error.Module (List Error.Module)
    | Report String (Maybe String) D.Doc


report : String -> Maybe String -> String -> List D.Doc -> Report
report title path startString others =
    Report title path <| D.stack (D.reflow startString :: others)


docReport : String -> Maybe String -> D.Doc -> List D.Doc -> Report
docReport title path startDoc others =
    Report title path <| D.stack (startDoc :: others)


jsonReport : String -> Maybe String -> D.Doc -> Report
jsonReport =
    Report


compilerReport : String -> Error.Module -> List Error.Module -> Report
compilerReport =
    CompilerReport



-- TO DOC


reportToDoc : Report -> D.Doc
reportToDoc report_ =
    case report_ of
        CompilerReport root e es ->
            Error.toDoc root e es

        Report title maybePath message ->
            let
                makeDashes n =
                    String.repeat (max 1 (80 - n)) "-"

                errorBarEnd =
                    case maybePath of
                        Nothing ->
                            makeDashes (4 + String.length title)

                        Just path ->
                            makeDashes (5 + String.length title + String.length path)
                                ++ " "
                                ++ path

                errorBar =
                    D.dullcyan
                        (D.fromChars "--"
                            |> D.plus (D.fromChars title)
                            |> D.plus (D.fromChars errorBarEnd)
                        )
            in
            D.stack [ errorBar, message, D.fromChars "" ]



-- TO JSON


reportToJson : Report -> E.Value
reportToJson report_ =
    case report_ of
        CompilerReport _ e es ->
            E.object
                [ ( "type", E.string "compile-errors" )
                , ( "errors", E.list Error.toJson (e :: es) )
                ]

        Report title maybePath message ->
            E.object
                [ ( "type", E.string "error" )
                , ( "path", Utils.maybe E.null E.string maybePath )
                , ( "title", E.string title )
                , ( "message", D.encode message )
                ]



-- OUTPUT


toString : D.Doc -> String
toString =
    D.toString


toStdout : D.Doc -> IO ()
toStdout doc =
    toHandle IO.stdout doc


toStderr : D.Doc -> IO ()
toStderr doc =
    toHandle IO.stderr doc


toHandle : IO.Handle -> D.Doc -> IO ()
toHandle handle doc =
    IO.hIsTerminalDevice handle
        |> IO.bind
            (\isTerminal ->
                if isTerminal then
                    D.toAnsi handle doc

                else
                    IO.hPutStr handle (toString doc)
            )
