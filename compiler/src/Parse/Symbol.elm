module Parse.Symbol exposing
    ( BadOperator(..)
    , badOperatorDecoder
    , badOperatorEncoder
    , binopCharSet
    , operator
    )

import Data.Name exposing (Name)
import Data.Set as EverySet exposing (EverySet)
import Json.Decode as Decode
import Json.Encode as Encode
import Parse.Primitives as P exposing (Col, Parser, Row)



-- OPERATOR


type BadOperator
    = BadDot
    | BadPipe
    | BadArrow
    | BadEquals
    | BadHasType


operator : (Row -> Col -> x) -> (BadOperator -> Row -> Col -> x) -> Parser x Name
operator toExpectation toError =
    P.Parser <|
        \(P.State src pos end indent row col) ->
            let
                newPos =
                    chompOps src pos end
            in
            if pos == newPos then
                Err (P.PErr P.Empty row col toExpectation)

            else
                case String.slice pos newPos src of
                    "." ->
                        Err (P.PErr P.Empty row col (toError BadDot))

                    "|" ->
                        Err (P.PErr P.Consumed row col (toError BadPipe))

                    "->" ->
                        Err (P.PErr P.Consumed row col (toError BadArrow))

                    "=" ->
                        Err (P.PErr P.Consumed row col (toError BadEquals))

                    ":" ->
                        Err (P.PErr P.Consumed row col (toError BadHasType))

                    op ->
                        let
                            newCol =
                                col + (newPos - pos)

                            newState =
                                P.State src newPos end indent row newCol
                        in
                        Ok (P.POk P.Consumed op newState)


chompOps : String -> Int -> Int -> Int
chompOps src pos end =
    if pos < end && isBinopChar src pos then
        chompOps src (pos + 1) end

    else
        pos


isBinopChar : String -> Int -> Bool
isBinopChar src pos =
    src
        |> String.dropLeft pos
        |> String.toList
        |> List.head
        |> Maybe.map isBinopCharHelp
        |> Maybe.withDefault False


isBinopCharHelp : Char -> Bool
isBinopCharHelp char =
    let
        code =
            Char.toCode char
    in
    EverySet.member code binopCharSet


binopCharSet : EverySet Int
binopCharSet =
    EverySet.fromList compare (List.map Char.toCode (String.toList "+-/*=.<>:&|^?%!"))



-- ENCODERS and DECODERS


badOperatorEncoder : BadOperator -> Encode.Value
badOperatorEncoder badOperator =
    case badOperator of
        BadDot ->
            Encode.string "BadDot"

        BadPipe ->
            Encode.string "BadPipe"

        BadArrow ->
            Encode.string "BadArrow"

        BadEquals ->
            Encode.string "BadEquals"

        BadHasType ->
            Encode.string "BadHasType"


badOperatorDecoder : Decode.Decoder BadOperator
badOperatorDecoder =
    Decode.string
        |> Decode.andThen
            (\str ->
                case str of
                    "BadDot" ->
                        Decode.succeed BadDot

                    "BadPipe" ->
                        Decode.succeed BadPipe

                    "BadArrow" ->
                        Decode.succeed BadArrow

                    "BadEquals" ->
                        Decode.succeed BadEquals

                    "BadHasType" ->
                        Decode.succeed BadHasType

                    _ ->
                        Decode.fail ("Unknown BadOperator: " ++ str)
            )
