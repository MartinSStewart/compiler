module Elm.Kernel exposing
    ( Chunk(..)
    , Content(..)
    , chunkDecoder
    , chunkEncoder
    , countFields
    , fromByteString
    )

import AST.Source as Src
import Data.Map as Dict exposing (Dict)
import Data.Name as Name exposing (Name)
import Elm.ModuleName as ModuleName
import Elm.Package as Pkg
import Json.Decode as Decode
import Json.Encode as Encode
import Parse.Module as Module
import Parse.Primitives as P exposing (Col, Row)
import Parse.Space as Space
import Parse.Variable as Var
import Reporting.Annotation as A
import Utils.Crash exposing (crash)



-- CHUNK


type Chunk
    = JS String
    | ElmVar ModuleName.Canonical Name
    | JsVar Name Name
    | ElmField Name
    | JsField Int
    | JsEnum Int
    | Debug
    | Prod



-- COUNT FIELDS


countFields : List Chunk -> Dict Name Int
countFields chunks =
    List.foldr addField Dict.empty chunks


addField : Chunk -> Dict Name Int -> Dict Name Int
addField chunk fields =
    case chunk of
        JS _ ->
            fields

        ElmVar _ _ ->
            fields

        JsVar _ _ ->
            fields

        ElmField f ->
            Dict.update compare
                f
                (Maybe.map ((+) 1)
                    >> Maybe.withDefault 1
                    >> Just
                )
                fields

        JsField _ ->
            fields

        JsEnum _ ->
            fields

        Debug ->
            fields

        Prod ->
            fields



-- FROM FILE


type Content
    = Content (List Src.Import) (List Chunk)


type alias Foreigns =
    Dict ModuleName.Raw Pkg.Name


fromByteString : Pkg.Name -> Foreigns -> String -> Maybe Content
fromByteString pkg foreigns bytes =
    case P.fromByteString (parser pkg foreigns) toError bytes of
        Ok content ->
            Just content

        Err () ->
            Nothing


parser : Pkg.Name -> Foreigns -> P.Parser () Content
parser pkg foreigns =
    P.word2 '/' '*' toError
        |> P.bind (\_ -> Space.chomp ignoreError)
        |> P.bind (\_ -> Space.checkFreshLine toError)
        |> P.bind (\_ -> P.specialize ignoreError (Module.chompImports []))
        |> P.bind
            (\imports ->
                P.word2 '*' '/' toError
                    |> P.bind (\_ -> parseChunks (toVarTable pkg foreigns imports) Dict.empty Dict.empty)
                    |> P.fmap (\chunks -> Content imports chunks)
            )


toError : Row -> Col -> ()
toError _ _ =
    ()


ignoreError : a -> Row -> Col -> ()
ignoreError _ _ _ =
    ()



-- PARSE CHUNKS


parseChunks : VarTable -> Enums -> Fields -> P.Parser () (List Chunk)
parseChunks vtable enums fields =
    P.Parser
        (\(P.State src pos end indent row col) ->
            let
                ( ( chunks, newPos ), ( newRow, newCol ) ) =
                    chompChunks vtable enums fields src pos end row col pos []
            in
            if newPos == end then
                Ok (P.POk P.Consumed chunks (P.State src newPos end indent newRow newCol))

            else
                Err (P.PErr P.Consumed row col toError)
        )


chompChunks : VarTable -> Enums -> Fields -> String -> Int -> Int -> Row -> Col -> Int -> List Chunk -> ( ( List Chunk, Int ), ( Row, Col ) )
chompChunks vs es fs src pos end row col lastPos revChunks =
    if pos >= end then
        let
            js =
                toByteString src lastPos end
        in
        ( ( List.reverse (JS js :: revChunks), pos ), ( row, col ) )

    else
        let
            word =
                P.unsafeIndex src pos
        in
        if word == '_' then
            let
                pos1 =
                    pos + 1

                pos3 =
                    pos + 3
            in
            if pos3 <= end && P.unsafeIndex src pos1 == '_' then
                let
                    js =
                        toByteString src lastPos pos
                in
                chompTag vs es fs src pos3 end row (col + 3) (JS js :: revChunks)

            else
                chompChunks vs es fs src pos1 end row (col + 1) lastPos revChunks

        else if word == '\n' then
            chompChunks vs es fs src (pos + 1) end (row + 1) 1 lastPos revChunks

        else
            let
                newPos =
                    pos + P.getCharWidth word
            in
            chompChunks vs es fs src newPos end row (col + 1) lastPos revChunks


type alias Enums =
    Dict Int (Dict Name Int)


type alias Fields =
    Dict Name Int


toByteString : String -> Int -> Int -> String
toByteString src pos end =
    let
        off =
            -- pos - unsafeForeignPtrToPtr src
            pos

        len =
            end - pos
    in
    String.slice off (off + len) src


chompTag : VarTable -> Enums -> Fields -> String -> Int -> Int -> Row -> Col -> List Chunk -> ( ( List Chunk, Int ), ( Row, Col ) )
chompTag vs es fs src pos end row col revChunks =
    let
        ( newPos, newCol ) =
            Var.chompInnerChars src pos end col

        tagPos =
            pos + -1

        word =
            P.unsafeIndex src tagPos
    in
    if word == '$' then
        let
            name =
                Name.fromPtr src pos newPos
        in
        chompChunks vs es fs src newPos end row newCol newPos <|
            (ElmField name :: revChunks)

    else
        let
            name =
                Name.fromPtr src tagPos newPos

            code =
                Char.toCode word
        in
        if code >= 0x30 && code <= 0x39 then
            let
                ( enum, newEnums ) =
                    lookupEnum (Char.fromCode (code - 0x30)) name es
            in
            chompChunks vs newEnums fs src newPos end row newCol newPos <|
                (JsEnum enum :: revChunks)

        else if code >= 0x61 && code <= 0x7A then
            let
                ( field, newFields ) =
                    lookupField name fs
            in
            chompChunks vs es newFields src newPos end row newCol newPos <|
                (JsField field :: revChunks)

        else if name == "DEBUG" then
            chompChunks vs es fs src newPos end row newCol newPos (Debug :: revChunks)

        else if name == "PROD" then
            chompChunks vs es fs src newPos end row newCol newPos (Prod :: revChunks)

        else
            case Dict.get name vs of
                Just chunk ->
                    chompChunks vs es fs src newPos end row newCol newPos (chunk :: revChunks)

                Nothing ->
                    ( ( revChunks, pos ), ( row, col ) )


lookupField : Name -> Fields -> ( Int, Fields )
lookupField name fields =
    case Dict.get name fields of
        Just n ->
            ( n, fields )

        Nothing ->
            let
                n =
                    Dict.size fields
            in
            ( n, Dict.insert compare name n fields )


lookupEnum : Char -> Name -> Enums -> ( Int, Enums )
lookupEnum word var allEnums =
    let
        code =
            Char.toCode word

        enums =
            Dict.get code allEnums
                |> Maybe.withDefault Dict.empty
    in
    case Dict.get var enums of
        Just n ->
            ( n, allEnums )

        Nothing ->
            let
                n =
                    Dict.size enums
            in
            ( n, Dict.insert compare code (Dict.insert compare var n enums) allEnums )



-- PROCESS IMPORTS


type alias VarTable =
    Dict Name Chunk


toVarTable : Pkg.Name -> Foreigns -> List Src.Import -> VarTable
toVarTable pkg foreigns imports =
    List.foldl (addImport pkg foreigns) Dict.empty imports


addImport : Pkg.Name -> Foreigns -> Src.Import -> VarTable -> VarTable
addImport pkg foreigns (Src.Import (A.At _ importName) maybeAlias exposing_) vtable =
    if Name.isKernel importName then
        case maybeAlias of
            Just _ ->
                crash ("cannot use `as` with kernel import of: " ++ importName)

            Nothing ->
                let
                    home =
                        Name.getKernel importName

                    add name table =
                        Dict.insert compare (Name.sepBy '_' home name) (JsVar home name) table
                in
                List.foldl add vtable (toNames exposing_)

    else
        let
            home =
                ModuleName.Canonical (Dict.get importName foreigns |> Maybe.withDefault pkg) importName

            prefix =
                toPrefix importName maybeAlias

            add name table =
                Dict.insert compare (Name.sepBy '_' prefix name) (ElmVar home name) table
        in
        List.foldl add vtable (toNames exposing_)


toPrefix : Name -> Maybe Name -> Name
toPrefix home maybeAlias =
    case maybeAlias of
        Just alias ->
            alias

        Nothing ->
            if Name.hasDot home then
                crash ("kernel imports with dots need an alias: " ++ home)

            else
                home


toNames : Src.Exposing -> List Name
toNames exposing_ =
    case exposing_ of
        Src.Open ->
            crash "cannot have `exposing (..)` in kernel code."

        Src.Explicit exposedList ->
            List.map toName exposedList


toName : Src.Exposed -> Name
toName exposed =
    case exposed of
        Src.Lower (A.At _ name) ->
            name

        Src.Upper (A.At _ name) Src.Private ->
            name

        Src.Upper _ (Src.Public _) ->
            crash "cannot have Maybe(..) syntax in kernel code header"

        Src.Operator _ _ ->
            crash "cannot use binops in kernel code"



-- ENCODERS and DECODERS


chunkEncoder : Chunk -> Encode.Value
chunkEncoder chunk =
    case chunk of
        JS javascript ->
            Encode.object
                [ ( "type", Encode.string "JS" )
                , ( "javascript", Encode.string javascript )
                ]

        ElmVar home name ->
            Encode.object
                [ ( "type", Encode.string "ElmVar" )
                , ( "home", ModuleName.canonicalEncoder home )
                , ( "name", Encode.string name )
                ]

        JsVar home name ->
            Encode.object
                [ ( "type", Encode.string "JsVar" )
                , ( "home", Encode.string home )
                , ( "name", Encode.string name )
                ]

        ElmField name ->
            Encode.object
                [ ( "type", Encode.string "ElmField" )
                , ( "name", Encode.string name )
                ]

        JsField int ->
            Encode.object
                [ ( "type", Encode.string "JsField" )
                , ( "int", Encode.int int )
                ]

        JsEnum int ->
            Encode.object
                [ ( "type", Encode.string "JsEnum" )
                , ( "int", Encode.int int )
                ]

        Debug ->
            Encode.object
                [ ( "type", Encode.string "Debug" )
                ]

        Prod ->
            Encode.object
                [ ( "type", Encode.string "Prod" )
                ]


chunkDecoder : Decode.Decoder Chunk
chunkDecoder =
    Decode.field "type" Decode.string
        |> Decode.andThen
            (\type_ ->
                case type_ of
                    "JS" ->
                        Decode.map JS (Decode.field "javascript" Decode.string)

                    "ElmVar" ->
                        Decode.map2 ElmVar
                            (Decode.field "home" ModuleName.canonicalDecoder)
                            (Decode.field "name" Decode.string)

                    "JsVar" ->
                        Decode.map2 JsVar
                            (Decode.field "home" Decode.string)
                            (Decode.field "name" Decode.string)

                    "ElmField" ->
                        Decode.map ElmField (Decode.field "name" Decode.string)

                    "JsField" ->
                        Decode.map JsField (Decode.field "int" Decode.int)

                    "JsEnum" ->
                        Decode.map JsEnum (Decode.field "int" Decode.int)

                    "Debug" ->
                        Decode.succeed Debug

                    "Prod" ->
                        Decode.succeed Prod

                    _ ->
                        Decode.fail ("Unknown Chunk's type: " ++ type_)
            )
