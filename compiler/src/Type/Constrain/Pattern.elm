module Type.Constrain.Pattern exposing
    ( State(..)
    , add
    , emptyState
    )

import AST.Canonical as Can
import Data.IO as IO exposing (IO)
import Data.Index as Index
import Data.Map as Dict exposing (Dict)
import Data.Name as Name
import Elm.ModuleName as ModuleName
import Reporting.Annotation as A
import Reporting.Error.Type as E
import Type.Instantiate as Instantiate
import Type.Type as Type exposing (Type)
import Type.UnionFind as UF
import Utils.Main as Utils



-- ACTUALLY ADD CONSTRAINTS
-- The constraints are stored in reverse order so that adding a new
-- constraint is O(1) and we can reverse it at some later time.
--


type State
    = State Header (List UF.Variable) (List Type.Constraint)


type alias Header =
    Dict Name.Name (A.Located Type)


add : Can.Pattern -> E.PExpected Type -> State -> IO State
add (A.At region pattern) expectation state =
    case pattern of
        Can.PAnything ->
            IO.pure state

        Can.PVar name ->
            IO.pure (addToHeaders region name expectation state)

        Can.PAlias realPattern name ->
            add realPattern expectation (addToHeaders region name expectation state)

        Can.PUnit ->
            let
                (State headers vars revCons) =
                    state

                unitCon =
                    Type.CPattern region E.PUnit Type.UnitN expectation
            in
            IO.pure (State headers vars (unitCon :: revCons))

        Can.PTuple a b maybeC ->
            addTuple region a b maybeC expectation state

        Can.PCtor { home, type_, union, name, args } ->
            let
                (Can.Union typeVars _ _ _) =
                    union
            in
            addCtor region home type_ typeVars name args expectation state

        Can.PList patterns ->
            Type.mkFlexVar
                |> IO.bind
                    (\entryVar ->
                        let
                            entryType =
                                Type.VarN entryVar

                            listType =
                                Type.AppN ModuleName.list Name.list [ entryType ]
                        in
                        Utils.ioFoldM (addEntry region entryType) state (Index.indexedMap Tuple.pair patterns)
                            |> IO.fmap
                                (\(State headers vars revCons) ->
                                    let
                                        listCon =
                                            Type.CPattern region E.PList listType expectation
                                    in
                                    State headers (entryVar :: vars) (listCon :: revCons)
                                )
                    )

        Can.PCons headPattern tailPattern ->
            Type.mkFlexVar
                |> IO.bind
                    (\entryVar ->
                        let
                            entryType =
                                Type.VarN entryVar

                            listType =
                                Type.AppN ModuleName.list Name.list [ entryType ]

                            headExpectation =
                                E.PNoExpectation entryType

                            tailExpectation =
                                E.PFromContext region E.PTail listType
                        in
                        add tailPattern tailExpectation state
                            |> IO.bind (add headPattern headExpectation)
                            |> IO.fmap
                                (\(State headers vars revCons) ->
                                    let
                                        listCon =
                                            Type.CPattern region E.PList listType expectation
                                    in
                                    State headers (entryVar :: vars) (listCon :: revCons)
                                )
                    )

        Can.PRecord fields ->
            Type.mkFlexVar
                |> IO.bind
                    (\extVar ->
                        let
                            extType =
                                Type.VarN extVar
                        in
                        Utils.listTraverse (\field -> IO.fmap (Tuple.pair field) Type.mkFlexVar) fields
                            |> IO.fmap
                                (\fieldVars ->
                                    let
                                        fieldTypes =
                                            Dict.fromList compare (List.map (Tuple.mapSecond Type.VarN) fieldVars)

                                        recordType =
                                            Type.RecordN fieldTypes extType

                                        (State headers vars revCons) =
                                            state

                                        recordCon =
                                            Type.CPattern region E.PRecord recordType expectation
                                    in
                                    State
                                        (Dict.union compare headers (Dict.map (\_ v -> A.At region v) fieldTypes))
                                        (List.map Tuple.second fieldVars ++ extVar :: vars)
                                        (recordCon :: revCons)
                                )
                    )

        Can.PInt _ ->
            let
                (State headers vars revCons) =
                    state

                intCon =
                    Type.CPattern region E.PInt Type.int expectation
            in
            IO.pure (State headers vars (intCon :: revCons))

        Can.PStr _ ->
            let
                (State headers vars revCons) =
                    state

                strCon =
                    Type.CPattern region E.PStr Type.string expectation
            in
            IO.pure (State headers vars (strCon :: revCons))

        Can.PChr _ ->
            let
                (State headers vars revCons) =
                    state

                chrCon =
                    Type.CPattern region E.PChr Type.char expectation
            in
            IO.pure (State headers vars (chrCon :: revCons))

        Can.PBool _ _ ->
            let
                (State headers vars revCons) =
                    state

                boolCon =
                    Type.CPattern region E.PBool Type.bool expectation
            in
            IO.pure (State headers vars (boolCon :: revCons))



-- STATE HELPERS


emptyState : State
emptyState =
    State Dict.empty [] []


addToHeaders : A.Region -> Name.Name -> E.PExpected Type -> State -> State
addToHeaders region name expectation (State headers vars revCons) =
    let
        tipe =
            getType expectation

        newHeaders =
            Dict.insert compare name (A.At region tipe) headers
    in
    State newHeaders vars revCons


getType : E.PExpected Type -> Type
getType expectation =
    case expectation of
        E.PNoExpectation tipe ->
            tipe

        E.PFromContext _ _ tipe ->
            tipe



-- CONSTRAIN LIST


addEntry : A.Region -> Type -> State -> ( Index.ZeroBased, Can.Pattern ) -> IO State
addEntry listRegion tipe state ( index, pattern ) =
    let
        expectation =
            E.PFromContext listRegion (E.PListEntry index) tipe
    in
    add pattern expectation state



-- CONSTRAIN TUPLE


addTuple : A.Region -> Can.Pattern -> Can.Pattern -> Maybe Can.Pattern -> E.PExpected Type -> State -> IO State
addTuple region a b maybeC expectation state =
    Type.mkFlexVar
        |> IO.bind
            (\aVar ->
                Type.mkFlexVar
                    |> IO.bind
                        (\bVar ->
                            let
                                aType =
                                    Type.VarN aVar

                                bType =
                                    Type.VarN bVar
                            in
                            case maybeC of
                                Nothing ->
                                    simpleAdd a aType state
                                        |> IO.bind (simpleAdd b bType)
                                        |> IO.fmap
                                            (\(State headers vars revCons) ->
                                                let
                                                    tupleCon =
                                                        Type.CPattern region E.PTuple (Type.TupleN aType bType Nothing) expectation
                                                in
                                                State headers (aVar :: bVar :: vars) (tupleCon :: revCons)
                                            )

                                Just c ->
                                    Type.mkFlexVar
                                        |> IO.bind
                                            (\cVar ->
                                                let
                                                    cType =
                                                        Type.VarN cVar
                                                in
                                                simpleAdd a aType state
                                                    |> IO.bind (simpleAdd b bType)
                                                    |> IO.bind (simpleAdd c cType)
                                                    |> IO.fmap
                                                        (\(State headers vars revCons) ->
                                                            let
                                                                tupleCon =
                                                                    Type.CPattern region E.PTuple (Type.TupleN aType bType (Just cType)) expectation
                                                            in
                                                            State headers (aVar :: bVar :: cVar :: vars) (tupleCon :: revCons)
                                                        )
                                            )
                        )
            )


simpleAdd : Can.Pattern -> Type -> State -> IO State
simpleAdd pattern patternType state =
    add pattern (E.PNoExpectation patternType) state



-- CONSTRAIN CONSTRUCTORS


addCtor : A.Region -> ModuleName.Canonical -> Name.Name -> List Name.Name -> Name.Name -> List Can.PatternCtorArg -> E.PExpected Type -> State -> IO State
addCtor region home typeName typeVarNames ctorName args expectation state =
    Utils.listTraverse (\var -> IO.fmap (Tuple.pair var) (Type.nameToFlex var)) typeVarNames
        |> IO.bind
            (\varPairs ->
                let
                    typePairs =
                        List.map (Tuple.mapSecond Type.VarN) varPairs

                    freeVarDict =
                        Dict.fromList compare typePairs
                in
                Utils.ioFoldM (addCtorArg region ctorName freeVarDict) state args
                    |> IO.bind
                        (\(State headers vars revCons) ->
                            let
                                ctorType =
                                    Type.AppN home typeName (List.map Tuple.second typePairs)

                                ctorCon =
                                    Type.CPattern region (E.PCtor ctorName) ctorType expectation
                            in
                            IO.pure <|
                                State headers
                                    (List.map Tuple.second varPairs ++ vars)
                                    (ctorCon :: revCons)
                        )
            )


addCtorArg : A.Region -> Name.Name -> Dict Name.Name Type -> State -> Can.PatternCtorArg -> IO State
addCtorArg region ctorName freeVarDict state (Can.PatternCtorArg index srcType pattern) =
    Instantiate.fromSrcType freeVarDict srcType
        |> IO.bind
            (\tipe ->
                let
                    expectation =
                        E.PFromContext region (E.PCtorArg ctorName index) tipe
                in
                add pattern expectation state
            )
