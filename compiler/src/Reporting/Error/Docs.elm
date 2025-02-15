module Reporting.Error.Docs exposing
    ( DefProblem(..)
    , Error(..)
    , NameProblem(..)
    , SyntaxProblem(..)
    , errorDecoder
    , errorEncoder
    , toReports
    )

import Data.Name as Name
import Data.NonEmptyList as NE
import Elm.Kernel exposing (Chunk(..))
import Json.Decode as Decode
import Json.DecodeX as DecodeX
import Json.Encode as Encode
import Json.EncodeX as EncodeX
import Parse.Primitives exposing (Col, Row)
import Parse.Symbol exposing (BadOperator(..))
import Reporting.Annotation as A
import Reporting.Doc as D
import Reporting.Error.Syntax as E
import Reporting.Render.Code as Code
import Reporting.Report as Report


type Error
    = NoDocs A.Region
    | ImplicitExposing A.Region
    | SyntaxProblem SyntaxProblem
    | NameProblems (NE.Nonempty NameProblem)
    | DefProblems (NE.Nonempty DefProblem)


type SyntaxProblem
    = Op Row Col
    | OpBad BadOperator Row Col
    | Name Row Col
    | Space E.Space Row Col
    | Comma Row Col
    | BadEnd Row Col


type NameProblem
    = NameDuplicate Name.Name A.Region A.Region
    | NameOnlyInDocs Name.Name A.Region
    | NameOnlyInExports Name.Name A.Region


type DefProblem
    = NoComment Name.Name A.Region
    | NoAnnotation Name.Name A.Region


toReports : Code.Source -> Error -> NE.Nonempty Report.Report
toReports source err =
    case err of
        NoDocs region ->
            NE.singleton <|
                Report.Report "NO DOCS" region [] <|
                    Code.toSnippet source
                        region
                        Nothing
                        ( D.reflow "You must have a documentation comment between the module declaration and the imports."
                        , D.reflow "Learn more at <https://package.elm-lang.org/help/documentation-format>"
                        )

        ImplicitExposing region ->
            NE.singleton <|
                Report.Report "IMPLICIT EXPOSING" region [] <|
                    Code.toSnippet source
                        region
                        Nothing
                        ( D.reflow "I need you to be explicit about what this module exposes:"
                        , D.reflow "A great API usually hides some implementation details, so it is rare that everything in the file should be exposed. And requiring package authors to be explicit about this is a way of adding another quality check before code gets published. So as you write out the public API, ask yourself if it will be easy to understand as people read the documentation!"
                        )

        SyntaxProblem problem ->
            NE.singleton <|
                toSyntaxProblemReport source problem

        NameProblems problems ->
            NE.map (toNameProblemReport source) problems

        DefProblems problems ->
            NE.map (toDefProblemReport source) problems


toSyntaxProblemReport : Code.Source -> SyntaxProblem -> Report.Report
toSyntaxProblemReport source problem =
    let
        toSyntaxReport row col details =
            let
                region =
                    toRegion row col
            in
            Report.Report "PROBLEM IN DOCS" region [] <|
                Code.toSnippet source
                    region
                    Nothing
                    ( D.reflow "I was partway through parsing your module documentation, but I got stuck here:"
                    , D.stack
                        [ D.reflow details
                        , D.toSimpleHint "Read through <https://package.elm-lang.org/help/documentation-format> for tips on how to write module documentation!"
                        ]
                    )
    in
    case problem of
        Op row col ->
            toSyntaxReport row col "I am trying to parse an operator like (+) or (*) but something is going wrong."

        OpBad _ row col ->
            toSyntaxReport row col "I am trying to parse an operator like (+) or (*) but it looks like you are using a reserved symbol in this case."

        Name row col ->
            toSyntaxReport row col "I was expecting to see the name of another exposed value from this module."

        Space space row col ->
            E.toSpaceReport source space row col

        Comma row col ->
            toSyntaxReport row col "I was expecting to see a comma next."

        BadEnd row col ->
            toSyntaxReport row col "I am not really sure what I am getting stuck on though."


toRegion : Row -> Col -> A.Region
toRegion row col =
    let
        pos =
            A.Position row col
    in
    A.Region pos pos


toNameProblemReport : Code.Source -> NameProblem -> Report.Report
toNameProblemReport source problem =
    case problem of
        NameDuplicate name r1 r2 ->
            Report.Report "DUPLICATE DOCS" r2 [] <|
                Code.toPair source
                    r1
                    r2
                    ( D.reflow ("There can only be one `" ++ name ++ "` in your module documentation, but it is listed twice:")
                    , D.fromChars "Remove one of them!"
                    )
                    ( D.reflow ("There can only be one `" ++ name ++ "` in your module documentation, but I see two. One here:")
                    , D.fromChars "And another one over here:"
                    , D.fromChars "Remove one of them!"
                    )

        NameOnlyInDocs name region ->
            Report.Report "DOCS MISTAKE" region [] <|
                Code.toSnippet source
                    region
                    Nothing
                    ( D.reflow ("I do not see `" ++ name ++ "` in the `exposing` list, but it is in your module documentation:")
                    , D.reflow ("Does it need to be added to the `exposing` list as well? Or maybe you removed `" ++ name ++ "` and forgot to delete it here?")
                    )

        NameOnlyInExports name region ->
            Report.Report "DOCS MISTAKE" region [] <|
                Code.toSnippet source
                    region
                    Nothing
                    ( D.reflow ("I do not see `" ++ name ++ "` in your module documentation, but it is in your `exposing` list:")
                    , D.stack
                        [ D.reflow ("Add a line like `@docs " ++ name ++ "` to your module documentation!")
                        , D.link "Note" "See" "docs" "for more guidance on writing high quality docs."
                        ]
                    )


toDefProblemReport : Code.Source -> DefProblem -> Report.Report
toDefProblemReport source problem =
    case problem of
        NoComment name region ->
            Report.Report "NO DOCS" region [] <|
                Code.toSnippet source
                    region
                    Nothing
                    ( D.reflow ("The `" ++ name ++ "` definition does not have a documentation comment.")
                    , D.stack
                        [ D.reflow "Add documentation with nice examples of how to use it!"
                        , D.link "Note" "Read" "docs" "for more advice on writing great docs. There are a couple important tricks!"
                        ]
                    )

        NoAnnotation name region ->
            Report.Report "NO TYPE ANNOTATION" region [] <|
                Code.toSnippet source
                    region
                    Nothing
                    ( D.reflow ("The `" ++ name ++ "` definition does not have a type annotation.")
                    , D.stack
                        [ D.reflow "I use the type variable names from your annotations when generating docs. So if you say `Html msg` in your type annotation, I can use `msg` in the docs and make them a bit clearer. So add an annotation and try to use nice type variables!"
                        , D.link "Note" "Read" "docs" "for more advice on writing great docs. There are a couple important tricks!"
                        ]
                    )



-- ENCODERS and DECODERS


errorEncoder : Error -> Encode.Value
errorEncoder error =
    case error of
        NoDocs region ->
            Encode.object
                [ ( "type", Encode.string "NoDocs" )
                , ( "region", A.regionEncoder region )
                ]

        ImplicitExposing region ->
            Encode.object
                [ ( "type", Encode.string "ImplicitExposing" )
                , ( "region", A.regionEncoder region )
                ]

        SyntaxProblem problem ->
            Encode.object
                [ ( "type", Encode.string "SyntaxProblem" )
                , ( "problem", syntaxProblemEncoder problem )
                ]

        NameProblems problems ->
            Encode.object
                [ ( "type", Encode.string "NameProblems" )
                , ( "problems", EncodeX.nonempty nameProblemEncoder problems )
                ]

        DefProblems problems ->
            Encode.object
                [ ( "type", Encode.string "DefProblems" )
                , ( "problems", EncodeX.nonempty defProblemEncoder problems )
                ]


errorDecoder : Decode.Decoder Error
errorDecoder =
    Decode.field "type" Decode.string
        |> Decode.andThen
            (\type_ ->
                case type_ of
                    "NoDocs" ->
                        Decode.map NoDocs (Decode.field "region" A.regionDecoder)

                    "ImplicitExposing" ->
                        Decode.map ImplicitExposing (Decode.field "region" A.regionDecoder)

                    "SyntaxProblem" ->
                        Decode.map SyntaxProblem (Decode.field "problem" syntaxProblemDecoder)

                    "NameProblems" ->
                        Decode.map NameProblems (Decode.field "problems" (DecodeX.nonempty nameProblemDecoder))

                    "DefProblems" ->
                        Decode.map DefProblems (Decode.field "problems" (DecodeX.nonempty defProblemDecoder))

                    _ ->
                        Decode.fail ("Failed to decode Error's type: " ++ type_)
            )


syntaxProblemEncoder : SyntaxProblem -> Encode.Value
syntaxProblemEncoder syntaxProblem =
    case syntaxProblem of
        Op row col ->
            Encode.object
                [ ( "type", Encode.string "Op" )
                , ( "row", Encode.int row )
                , ( "col", Encode.int col )
                ]

        OpBad badOperator row col ->
            Encode.object
                [ ( "type", Encode.string "OpBad" )
                , ( "badOperator", Parse.Symbol.badOperatorEncoder badOperator )
                , ( "row", Encode.int row )
                , ( "col", Encode.int col )
                ]

        Name row col ->
            Encode.object
                [ ( "type", Encode.string "Name" )
                , ( "row", Encode.int row )
                , ( "col", Encode.int col )
                ]

        Space name row col ->
            Encode.object
                [ ( "type", Encode.string "Space" )
                , ( "name", E.spaceEncoder name )
                , ( "row", Encode.int row )
                , ( "col", Encode.int col )
                ]

        Comma row col ->
            Encode.object
                [ ( "type", Encode.string "Comma" )
                , ( "row", Encode.int row )
                , ( "col", Encode.int col )
                ]

        BadEnd row col ->
            Encode.object
                [ ( "type", Encode.string "BadEnd" )
                , ( "row", Encode.int row )
                , ( "col", Encode.int col )
                ]


syntaxProblemDecoder : Decode.Decoder SyntaxProblem
syntaxProblemDecoder =
    Decode.field "type" Decode.string
        |> Decode.andThen
            (\type_ ->
                case type_ of
                    "Op" ->
                        Decode.map2 Op
                            (Decode.field "row" Decode.int)
                            (Decode.field "col" Decode.int)

                    "OpBad" ->
                        Decode.map3 OpBad
                            (Decode.field "badOperator" Parse.Symbol.badOperatorDecoder)
                            (Decode.field "row" Decode.int)
                            (Decode.field "col" Decode.int)

                    "Name" ->
                        Decode.map2 Name
                            (Decode.field "row" Decode.int)
                            (Decode.field "col" Decode.int)

                    "Space" ->
                        Decode.map3 Space
                            (Decode.field "name" E.spaceDecoder)
                            (Decode.field "row" Decode.int)
                            (Decode.field "col" Decode.int)

                    "Comma" ->
                        Decode.map2 Comma
                            (Decode.field "row" Decode.int)
                            (Decode.field "col" Decode.int)

                    "BadEnd" ->
                        Decode.map2 BadEnd
                            (Decode.field "row" Decode.int)
                            (Decode.field "col" Decode.int)

                    _ ->
                        Decode.fail ("Failed to decode SyntaxProblem's type: " ++ type_)
            )


nameProblemEncoder : NameProblem -> Encode.Value
nameProblemEncoder nameProblem =
    case nameProblem of
        NameDuplicate name r1 r2 ->
            Encode.object
                [ ( "type", Encode.string "NameDuplicate" )
                , ( "name", Encode.string name )
                , ( "r1", A.regionEncoder r1 )
                , ( "r2", A.regionEncoder r2 )
                ]

        NameOnlyInDocs name region ->
            Encode.object
                [ ( "type", Encode.string "NameOnlyInDocs" )
                , ( "name", Encode.string name )
                , ( "region", A.regionEncoder region )
                ]

        NameOnlyInExports name region ->
            Encode.object
                [ ( "type", Encode.string "NameOnlyInExports" )
                , ( "name", Encode.string name )
                , ( "region", A.regionEncoder region )
                ]


nameProblemDecoder : Decode.Decoder NameProblem
nameProblemDecoder =
    Decode.field "type" Decode.string
        |> Decode.andThen
            (\type_ ->
                case type_ of
                    "NameDuplicate" ->
                        Decode.map3 NameDuplicate
                            (Decode.field "name" Decode.string)
                            (Decode.field "r1" A.regionDecoder)
                            (Decode.field "r2" A.regionDecoder)

                    "NameOnlyInDocs" ->
                        Decode.map2 NameOnlyInDocs
                            (Decode.field "name" Decode.string)
                            (Decode.field "region" A.regionDecoder)

                    "NameOnlyInExports" ->
                        Decode.map2 NameOnlyInExports
                            (Decode.field "name" Decode.string)
                            (Decode.field "region" A.regionDecoder)

                    _ ->
                        Decode.fail ("Failed to decode NameProblem's type: " ++ type_)
            )


defProblemEncoder : DefProblem -> Encode.Value
defProblemEncoder defProblem =
    case defProblem of
        NoComment name region ->
            Encode.object
                [ ( "type", Encode.string "NoComment" )
                , ( "name", Encode.string name )
                , ( "region", A.regionEncoder region )
                ]

        NoAnnotation name region ->
            Encode.object
                [ ( "type", Encode.string "NoAnnotation" )
                , ( "name", Encode.string name )
                , ( "region", A.regionEncoder region )
                ]


defProblemDecoder : Decode.Decoder DefProblem
defProblemDecoder =
    Decode.field "type" Decode.string
        |> Decode.andThen
            (\type_ ->
                case type_ of
                    "NoComment" ->
                        Decode.map2 NoComment
                            (Decode.field "name" Decode.string)
                            (Decode.field "region" A.regionDecoder)

                    "NoAnnotation" ->
                        Decode.map2 NoAnnotation
                            (Decode.field "name" Decode.string)
                            (Decode.field "region" A.regionDecoder)

                    _ ->
                        Decode.fail ("Failed to decode DefProblem's type: " ++ type_)
            )
