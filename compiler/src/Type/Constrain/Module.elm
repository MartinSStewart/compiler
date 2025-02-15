module Type.Constrain.Module exposing (constrain)

import AST.Canonical as Can
import Data.IO as IO exposing (IO)
import Data.Map as Dict
import Data.Name as Name exposing (Name)
import Elm.ModuleName as ModuleName
import Reporting.Annotation as A
import Reporting.Error.Type as E
import Type.Constrain.Expression as Expr
import Type.Instantiate as Instantiate
import Type.Type as Type exposing (Constraint(..), Type(..), mkFlexVar, nameToRigid)
import Utils.Main as Utils



-- CONSTRAIN


constrain : Can.Module -> IO Constraint
constrain (Can.Module home _ _ decls _ _ _ effects) =
    case effects of
        Can.NoEffects ->
            constrainDecls decls CSaveTheEnvironment

        Can.Ports ports ->
            Dict.foldr letPort (constrainDecls decls CSaveTheEnvironment) ports

        Can.Manager r0 r1 r2 manager ->
            case manager of
                Can.Cmd cmdName ->
                    constrainEffects home r0 r1 r2 manager
                        |> IO.bind (constrainDecls decls)
                        |> IO.bind (letCmd home cmdName)

                Can.Sub subName ->
                    constrainEffects home r0 r1 r2 manager
                        |> IO.bind (constrainDecls decls)
                        |> IO.bind (letSub home subName)

                Can.Fx cmdName subName ->
                    constrainEffects home r0 r1 r2 manager
                        |> IO.bind (constrainDecls decls)
                        |> IO.bind (letSub home subName)
                        |> IO.bind (letCmd home cmdName)



-- CONSTRAIN DECLARATIONS


constrainDecls : Can.Decls -> Constraint -> IO Constraint
constrainDecls decls finalConstraint =
    case decls of
        Can.Declare def otherDecls ->
            IO.bind (Expr.constrainDef Dict.empty def) (constrainDecls otherDecls finalConstraint)

        Can.DeclareRec def defs otherDecls ->
            IO.bind (Expr.constrainRecursiveDefs Dict.empty (def :: defs)) (constrainDecls otherDecls finalConstraint)

        Can.SaveTheEnvironment ->
            IO.pure finalConstraint



-- PORT HELPERS


letPort : Name -> Can.Port -> IO Constraint -> IO Constraint
letPort name port_ makeConstraint =
    case port_ of
        Can.Incoming { freeVars, func } ->
            Utils.mapTraverseWithKey compare (\k _ -> nameToRigid k) freeVars
                |> IO.bind
                    (\vars ->
                        Instantiate.fromSrcType (Dict.map (\_ v -> VarN v) vars) func
                            |> IO.bind
                                (\tipe ->
                                    let
                                        header =
                                            Dict.singleton name (A.At A.zero tipe)
                                    in
                                    IO.fmap (CLet (Dict.values vars) [] header CTrue) makeConstraint
                                )
                    )

        Can.Outgoing { freeVars, func } ->
            Utils.mapTraverseWithKey compare (\k _ -> nameToRigid k) freeVars
                |> IO.bind
                    (\vars ->
                        Instantiate.fromSrcType (Dict.map (\_ v -> VarN v) vars) func
                            |> IO.bind
                                (\tipe ->
                                    let
                                        header =
                                            Dict.singleton name (A.At A.zero tipe)
                                    in
                                    IO.fmap (CLet (Dict.values vars) [] header CTrue) makeConstraint
                                )
                    )



-- EFFECT MANAGER HELPERS


letCmd : ModuleName.Canonical -> Name -> Constraint -> IO Constraint
letCmd home tipe constraint =
    mkFlexVar
        |> IO.fmap
            (\msgVar ->
                let
                    msg =
                        VarN msgVar

                    cmdType =
                        FunN (AppN home tipe [ msg ]) (AppN ModuleName.cmd Name.cmd [ msg ])

                    header =
                        Dict.singleton "command" (A.At A.zero cmdType)
                in
                CLet [ msgVar ] [] header CTrue constraint
            )


letSub : ModuleName.Canonical -> Name -> Constraint -> IO Constraint
letSub home tipe constraint =
    mkFlexVar
        |> IO.fmap
            (\msgVar ->
                let
                    msg =
                        VarN msgVar

                    subType =
                        FunN (AppN home tipe [ msg ]) (AppN ModuleName.sub Name.sub [ msg ])

                    header =
                        Dict.singleton "subscription" (A.At A.zero subType)
                in
                CLet [ msgVar ] [] header CTrue constraint
            )


constrainEffects : ModuleName.Canonical -> A.Region -> A.Region -> A.Region -> Can.Manager -> IO Constraint
constrainEffects home r0 r1 r2 manager =
    mkFlexVar
        |> IO.bind
            (\s0 ->
                mkFlexVar
                    |> IO.bind
                        (\s1 ->
                            mkFlexVar
                                |> IO.bind
                                    (\s2 ->
                                        mkFlexVar
                                            |> IO.bind
                                                (\m1 ->
                                                    mkFlexVar
                                                        |> IO.bind
                                                            (\m2 ->
                                                                mkFlexVar
                                                                    |> IO.bind
                                                                        (\sm1 ->
                                                                            mkFlexVar
                                                                                |> IO.bind
                                                                                    (\sm2 ->
                                                                                        let
                                                                                            state0 =
                                                                                                VarN s0

                                                                                            state1 =
                                                                                                VarN s1

                                                                                            state2 =
                                                                                                VarN s2

                                                                                            msg1 =
                                                                                                VarN m1

                                                                                            msg2 =
                                                                                                VarN m2

                                                                                            self1 =
                                                                                                VarN sm1

                                                                                            self2 =
                                                                                                VarN sm2

                                                                                            onSelfMsg =
                                                                                                Type.funType (router msg2 self2) (Type.funType self2 (Type.funType state2 (task state2)))

                                                                                            onEffects =
                                                                                                case manager of
                                                                                                    Can.Cmd cmd ->
                                                                                                        Type.funType (router msg1 self1) (Type.funType (effectList home cmd msg1) (Type.funType state1 (task state1)))

                                                                                                    Can.Sub sub ->
                                                                                                        Type.funType (router msg1 self1) (Type.funType (effectList home sub msg1) (Type.funType state1 (task state1)))

                                                                                                    Can.Fx cmd sub ->
                                                                                                        Type.funType (router msg1 self1) (Type.funType (effectList home cmd msg1) (Type.funType (effectList home sub msg1) (Type.funType state1 (task state1))))

                                                                                            effectCons =
                                                                                                CAnd
                                                                                                    [ CLocal r0 "init" (E.NoExpectation (task state0))
                                                                                                    , CLocal r1 "onEffects" (E.NoExpectation onEffects)
                                                                                                    , CLocal r2 "onSelfMsg" (E.NoExpectation onSelfMsg)
                                                                                                    , CEqual r1 E.Effects state0 (E.NoExpectation state1)
                                                                                                    , CEqual r2 E.Effects state0 (E.NoExpectation state2)
                                                                                                    , CEqual r2 E.Effects self1 (E.NoExpectation self2)
                                                                                                    ]
                                                                                        in
                                                                                        IO.fmap (CLet [] [ s0, s1, s2, m1, m2, sm1, sm2 ] Dict.empty effectCons)
                                                                                            (case manager of
                                                                                                Can.Cmd cmd ->
                                                                                                    checkMap "cmdMap" home cmd CSaveTheEnvironment

                                                                                                Can.Sub sub ->
                                                                                                    checkMap "subMap" home sub CSaveTheEnvironment

                                                                                                Can.Fx cmd sub ->
                                                                                                    IO.bind (checkMap "cmdMap" home cmd)
                                                                                                        (checkMap "subMap" home sub CSaveTheEnvironment)
                                                                                            )
                                                                                    )
                                                                        )
                                                            )
                                                )
                                    )
                        )
            )


effectList : ModuleName.Canonical -> Name -> Type -> Type
effectList home name msg =
    AppN ModuleName.list Name.list [ AppN home name [ msg ] ]


task : Type -> Type
task answer =
    AppN ModuleName.platform Name.task [ Type.never, answer ]


router : Type -> Type -> Type
router msg self =
    AppN ModuleName.platform Name.router [ msg, self ]


checkMap : Name -> ModuleName.Canonical -> Name -> Constraint -> IO Constraint
checkMap name home tipe constraint =
    mkFlexVar
        |> IO.bind
            (\a ->
                mkFlexVar
                    |> IO.fmap
                        (\b ->
                            let
                                mapType =
                                    toMapType home tipe (VarN a) (VarN b)

                                mapCon =
                                    CLocal A.zero name (E.NoExpectation mapType)
                            in
                            CLet [ a, b ] [] Dict.empty mapCon constraint
                        )
            )


toMapType : ModuleName.Canonical -> Name -> Type -> Type -> Type
toMapType home tipe a b =
    Type.funType (Type.funType a b) (Type.funType (AppN home tipe [ a ]) (AppN home tipe [ b ]))
