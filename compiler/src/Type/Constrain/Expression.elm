module Type.Constrain.Expression exposing
    ( constrain
    , constrainDef
    , constrainRecursiveDefs
    )

import AST.Canonical as Can
import AST.Utils.Shader as Shader
import Data.IO as IO exposing (IO)
import Data.Index as Index
import Data.Map as Dict exposing (Dict)
import Data.Name as Name exposing (Name)
import Elm.ModuleName as ModuleName
import Reporting.Annotation as A
import Reporting.Error.Type as E exposing (..)
import Type.Constrain.Pattern as Pattern
import Type.Instantiate as Instantiate
import Type.Type as Type exposing (..)
import Type.UnionFind as UF
import Utils.Main as Utils



-- CONSTRAIN


{-| As we step past type annotations, the free type variables are added to
the "rigid type variables" dict. Allowing sharing of rigid variables
between nested type annotations.

So if you have a top-level type annotation like (func : a -> b) the RTV
dictionary will hold variables for `a` and `b`

-}
type alias RTV =
    Dict Name.Name Type


constrain : RTV -> Can.Expr -> E.Expected Type -> IO Constraint
constrain rtv (A.At region expression) expected =
    case expression of
        Can.VarLocal name ->
            IO.pure (CLocal region name expected)

        Can.VarTopLevel _ name ->
            IO.pure (CLocal region name expected)

        Can.VarKernel _ _ ->
            IO.pure CTrue

        Can.VarForeign _ name annotation ->
            IO.pure (CForeign region name annotation expected)

        Can.VarCtor _ _ name _ annotation ->
            IO.pure (CForeign region name annotation expected)

        Can.VarDebug _ name annotation ->
            IO.pure (CForeign region name annotation expected)

        Can.VarOperator op _ _ annotation ->
            IO.pure (CForeign region op annotation expected)

        Can.Str _ ->
            IO.pure (CEqual region String Type.string expected)

        Can.Chr _ ->
            IO.pure (CEqual region Char Type.char expected)

        Can.Int _ ->
            mkFlexNumber
                |> IO.fmap
                    (\var ->
                        exists [ var ] (CEqual region E.Number (VarN var) expected)
                    )

        Can.Float _ ->
            IO.pure (CEqual region Float Type.float expected)

        Can.List elements ->
            constrainList rtv region elements expected

        Can.Negate expr ->
            mkFlexNumber
                |> IO.bind
                    (\numberVar ->
                        let
                            numberType =
                                VarN numberVar
                        in
                        constrain rtv expr (FromContext region Negate numberType)
                            |> IO.fmap
                                (\numberCon ->
                                    let
                                        negateCon =
                                            CEqual region E.Number numberType expected
                                    in
                                    exists [ numberVar ] (CAnd [ numberCon, negateCon ])
                                )
                    )

        Can.Binop op _ _ annotation leftExpr rightExpr ->
            constrainBinop rtv region op annotation leftExpr rightExpr expected

        Can.Lambda args body ->
            constrainLambda rtv region args body expected

        Can.Call func args ->
            constrainCall rtv region func args expected

        Can.If branches finally ->
            constrainIf rtv region branches finally expected

        Can.Case expr branches ->
            constrainCase rtv region expr branches expected

        Can.Let def body ->
            IO.bind (constrainDef rtv def)
                (constrain rtv body expected)

        Can.LetRec defs body ->
            IO.bind (constrainRecursiveDefs rtv defs)
                (constrain rtv body expected)

        Can.LetDestruct pattern expr body ->
            IO.bind (constrainDestruct rtv region pattern expr)
                (constrain rtv body expected)

        Can.Accessor field ->
            mkFlexVar
                |> IO.bind
                    (\extVar ->
                        mkFlexVar
                            |> IO.fmap
                                (\fieldVar ->
                                    let
                                        extType =
                                            VarN extVar

                                        fieldType =
                                            VarN fieldVar

                                        recordType =
                                            RecordN (Dict.singleton field fieldType) extType
                                    in
                                    exists [ fieldVar, extVar ] (CEqual region (Accessor field) (FunN recordType fieldType) expected)
                                )
                    )

        Can.Access expr (A.At accessRegion field) ->
            mkFlexVar
                |> IO.bind
                    (\extVar ->
                        mkFlexVar
                            |> IO.bind
                                (\fieldVar ->
                                    let
                                        extType =
                                            VarN extVar

                                        fieldType =
                                            VarN fieldVar

                                        recordType =
                                            RecordN (Dict.singleton field fieldType) extType

                                        context =
                                            RecordAccess (A.toRegion expr) (getAccessName expr) accessRegion field
                                    in
                                    constrain rtv expr (FromContext region context recordType)
                                        |> IO.fmap
                                            (\recordCon ->
                                                exists [ fieldVar, extVar ] (CAnd [ recordCon, CEqual region (Access field) fieldType expected ])
                                            )
                                )
                    )

        Can.Update name expr fields ->
            constrainUpdate rtv region name expr fields expected

        Can.Record fields ->
            constrainRecord rtv region fields expected

        Can.Unit ->
            IO.pure (CEqual region Unit UnitN expected)

        Can.Tuple a b maybeC ->
            constrainTuple rtv region a b maybeC expected

        Can.Shader _ types ->
            constrainShader region types expected



-- CONSTRAIN LAMBDA


constrainLambda : RTV -> A.Region -> List Can.Pattern -> Can.Expr -> E.Expected Type -> IO Constraint
constrainLambda rtv region args body expected =
    constrainArgs args
        |> IO.bind
            (\(Args vars tipe resultType (Pattern.State headers pvars revCons)) ->
                constrain rtv body (NoExpectation resultType)
                    |> IO.fmap
                        (\bodyCon ->
                            exists vars <|
                                CAnd
                                    [ CLet []
                                        pvars
                                        headers
                                        (CAnd (List.reverse revCons))
                                        bodyCon
                                    , CEqual region Lambda tipe expected
                                    ]
                        )
            )



-- CONSTRAIN CALL


constrainCall : RTV -> A.Region -> Can.Expr -> List Can.Expr -> E.Expected Type -> IO Constraint
constrainCall rtv region ((A.At funcRegion _) as func) args expected =
    let
        maybeName =
            getName func
    in
    mkFlexVar
        |> IO.bind
            (\funcVar ->
                mkFlexVar
                    |> IO.bind
                        (\resultVar ->
                            let
                                funcType =
                                    VarN funcVar

                                resultType =
                                    VarN resultVar
                            in
                            constrain rtv func (E.NoExpectation funcType)
                                |> IO.bind
                                    (\funcCon ->
                                        IO.fmap Utils.unzip3 (Utils.indexedTraverse (constrainArg rtv region maybeName) args)
                                            |> IO.fmap
                                                (\( argVars, argTypes, argCons ) ->
                                                    let
                                                        arityType =
                                                            List.foldr FunN resultType argTypes

                                                        category =
                                                            CallResult maybeName
                                                    in
                                                    exists (funcVar :: resultVar :: argVars)
                                                        (CAnd
                                                            [ funcCon
                                                            , CEqual funcRegion category funcType (FromContext region (CallArity maybeName (List.length args)) arityType)
                                                            , CAnd argCons
                                                            , CEqual region category resultType expected
                                                            ]
                                                        )
                                                )
                                    )
                        )
            )


constrainArg : RTV -> A.Region -> E.MaybeName -> Index.ZeroBased -> Can.Expr -> IO ( UF.Variable, Type, Constraint )
constrainArg rtv region maybeName index arg =
    mkFlexVar
        |> IO.bind
            (\argVar ->
                let
                    argType =
                        VarN argVar
                in
                constrain rtv arg (FromContext region (CallArg maybeName index) argType)
                    |> IO.fmap
                        (\argCon ->
                            ( argVar, argType, argCon )
                        )
            )


getName : Can.Expr -> MaybeName
getName (A.At _ expr) =
    case expr of
        Can.VarLocal name ->
            FuncName name

        Can.VarTopLevel _ name ->
            FuncName name

        Can.VarForeign _ name _ ->
            FuncName name

        Can.VarCtor _ _ name _ _ ->
            CtorName name

        Can.VarOperator op _ _ _ ->
            OpName op

        Can.VarKernel _ name ->
            FuncName name

        _ ->
            NoName


getAccessName : Can.Expr -> Maybe Name.Name
getAccessName (A.At _ expr) =
    case expr of
        Can.VarLocal name ->
            Just name

        Can.VarTopLevel _ name ->
            Just name

        Can.VarForeign _ name _ ->
            Just name

        _ ->
            Nothing



-- CONSTRAIN BINOP


constrainBinop : RTV -> A.Region -> Name.Name -> Can.Annotation -> Can.Expr -> Can.Expr -> E.Expected Type -> IO Constraint
constrainBinop rtv region op annotation leftExpr rightExpr expected =
    mkFlexVar
        |> IO.bind
            (\leftVar ->
                mkFlexVar
                    |> IO.bind
                        (\rightVar ->
                            mkFlexVar
                                |> IO.bind
                                    (\answerVar ->
                                        let
                                            leftType =
                                                VarN leftVar

                                            rightType =
                                                VarN rightVar

                                            answerType =
                                                VarN answerVar

                                            binopType =
                                                Type.funType leftType (Type.funType rightType answerType)

                                            opCon =
                                                CForeign region op annotation (NoExpectation binopType)
                                        in
                                        constrain rtv leftExpr (FromContext region (OpLeft op) leftType)
                                            |> IO.bind
                                                (\leftCon ->
                                                    constrain rtv rightExpr (FromContext region (OpRight op) rightType)
                                                        |> IO.fmap
                                                            (\rightCon ->
                                                                exists [ leftVar, rightVar, answerVar ]
                                                                    (CAnd
                                                                        [ opCon
                                                                        , leftCon
                                                                        , rightCon
                                                                        , CEqual region (CallResult (OpName op)) answerType expected
                                                                        ]
                                                                    )
                                                            )
                                                )
                                    )
                        )
            )



-- CONSTRAIN LISTS


constrainList : RTV -> A.Region -> List Can.Expr -> E.Expected Type -> IO Constraint
constrainList rtv region entries expected =
    mkFlexVar
        |> IO.bind
            (\entryVar ->
                let
                    entryType =
                        VarN entryVar

                    listType =
                        AppN ModuleName.list Name.list [ entryType ]
                in
                Utils.indexedTraverse (constrainListEntry rtv region entryType) entries
                    |> IO.fmap
                        (\entryCons ->
                            exists [ entryVar ]
                                (CAnd
                                    [ CAnd entryCons
                                    , CEqual region List listType expected
                                    ]
                                )
                        )
            )


constrainListEntry : RTV -> A.Region -> Type -> Index.ZeroBased -> Can.Expr -> IO Constraint
constrainListEntry rtv region tipe index expr =
    constrain rtv expr (FromContext region (ListEntry index) tipe)



-- CONSTRAIN IF EXPRESSIONS


constrainIf : RTV -> A.Region -> List ( Can.Expr, Can.Expr ) -> Can.Expr -> E.Expected Type -> IO Constraint
constrainIf rtv region branches final expected =
    let
        boolExpect =
            FromContext region IfCondition Type.bool

        ( conditions, exprs ) =
            List.foldr (\( c, e ) ( cs, es ) -> ( c :: cs, e :: es )) ( [], [ final ] ) branches
    in
    Utils.listTraverse (\c -> constrain rtv c boolExpect) conditions
        |> IO.bind
            (\condCons ->
                case expected of
                    FromAnnotation name arity _ tipe ->
                        Utils.indexedForA exprs (\index expr -> constrain rtv expr (FromAnnotation name arity (TypedIfBranch index) tipe))
                            |> IO.fmap
                                (\branchCons ->
                                    CAnd (CAnd condCons :: branchCons)
                                )

                    _ ->
                        mkFlexVar
                            |> IO.bind
                                (\branchVar ->
                                    let
                                        branchType =
                                            VarN branchVar
                                    in
                                    Utils.indexedForA exprs
                                        (\index expr ->
                                            constrain rtv expr (FromContext region (IfBranch index) branchType)
                                        )
                                        |> IO.fmap
                                            (\branchCons ->
                                                exists [ branchVar ]
                                                    (CAnd
                                                        [ CAnd condCons
                                                        , CAnd branchCons
                                                        , CEqual region If branchType expected
                                                        ]
                                                    )
                                            )
                                )
            )



-- CONSTRAIN CASE EXPRESSIONS


constrainCase : RTV -> A.Region -> Can.Expr -> List Can.CaseBranch -> Expected Type -> IO Constraint
constrainCase rtv region expr branches expected =
    mkFlexVar
        |> IO.bind
            (\ptrnVar ->
                let
                    ptrnType =
                        VarN ptrnVar
                in
                constrain rtv expr (NoExpectation ptrnType)
                    |> IO.bind
                        (\exprCon ->
                            case expected of
                                FromAnnotation name arity _ tipe ->
                                    Utils.indexedForA branches
                                        (\index branch ->
                                            constrainCaseBranch rtv
                                                branch
                                                (PFromContext region (PCaseMatch index) ptrnType)
                                                (FromAnnotation name arity (TypedCaseBranch index) tipe)
                                        )
                                        |> IO.fmap
                                            (\branchCons ->
                                                exists [ ptrnVar ] (CAnd (exprCon :: branchCons))
                                            )

                                _ ->
                                    mkFlexVar
                                        |> IO.bind
                                            (\branchVar ->
                                                let
                                                    branchType =
                                                        VarN branchVar
                                                in
                                                Utils.indexedForA branches
                                                    (\index branch ->
                                                        constrainCaseBranch rtv
                                                            branch
                                                            (PFromContext region (PCaseMatch index) ptrnType)
                                                            (FromContext region (CaseBranch index) branchType)
                                                    )
                                                    |> IO.fmap
                                                        (\branchCons ->
                                                            exists [ ptrnVar, branchVar ]
                                                                (CAnd
                                                                    [ exprCon
                                                                    , CAnd branchCons
                                                                    , CEqual region Case branchType expected
                                                                    ]
                                                                )
                                                        )
                                            )
                        )
            )


constrainCaseBranch : RTV -> Can.CaseBranch -> PExpected Type -> Expected Type -> IO Constraint
constrainCaseBranch rtv (Can.CaseBranch pattern expr) pExpect bExpect =
    Pattern.add pattern pExpect Pattern.emptyState
        |> IO.bind
            (\(Pattern.State headers pvars revCons) ->
                IO.fmap (CLet [] pvars headers (CAnd (List.reverse revCons)))
                    (constrain rtv expr bExpect)
            )



-- CONSTRAIN RECORD


constrainRecord : RTV -> A.Region -> Dict Name.Name Can.Expr -> Expected Type -> IO Constraint
constrainRecord rtv region fields expected =
    Utils.mapTraverse compare (constrainField rtv) fields
        |> IO.fmap
            (\dict ->
                let
                    getType _ ( _, t, _ ) =
                        t

                    recordType =
                        RecordN (Dict.map getType dict) EmptyRecordN

                    recordCon =
                        CEqual region Record recordType expected

                    vars =
                        Dict.foldr (\_ ( v, _, _ ) vs -> v :: vs) [] dict

                    cons =
                        Dict.foldr (\_ ( _, _, c ) cs -> c :: cs) [ recordCon ] dict
                in
                exists vars (CAnd cons)
            )


constrainField : RTV -> Can.Expr -> IO ( UF.Variable, Type, Constraint )
constrainField rtv expr =
    mkFlexVar
        |> IO.bind
            (\var ->
                let
                    tipe =
                        VarN var
                in
                constrain rtv expr (NoExpectation tipe)
                    |> IO.fmap
                        (\con ->
                            ( var, tipe, con )
                        )
            )



-- CONSTRAIN RECORD UPDATE


constrainUpdate : RTV -> A.Region -> Name.Name -> Can.Expr -> Dict Name.Name Can.FieldUpdate -> Expected Type -> IO Constraint
constrainUpdate rtv region name expr fields expected =
    mkFlexVar
        |> IO.bind
            (\extVar ->
                Utils.mapTraverseWithKey compare (constrainUpdateField rtv region) fields
                    |> IO.bind
                        (\fieldDict ->
                            mkFlexVar
                                |> IO.bind
                                    (\recordVar ->
                                        let
                                            recordType =
                                                VarN recordVar

                                            fieldsType =
                                                RecordN (Dict.map (\_ ( _, t, _ ) -> t) fieldDict) (VarN extVar)

                                            -- NOTE: fieldsType is separate so that Error propagates better
                                            fieldsCon =
                                                CEqual region Record recordType (NoExpectation fieldsType)

                                            recordCon =
                                                CEqual region Record recordType expected

                                            vars =
                                                Dict.foldr (\_ ( v, _, _ ) vs -> v :: vs) [ recordVar, extVar ] fieldDict

                                            cons =
                                                Dict.foldr (\_ ( _, _, c ) cs -> c :: cs) [ recordCon ] fieldDict
                                        in
                                        constrain rtv expr (FromContext region (RecordUpdateKeys name fields) recordType)
                                            |> IO.fmap (\con -> exists vars (CAnd (fieldsCon :: con :: cons)))
                                    )
                        )
            )


constrainUpdateField : RTV -> A.Region -> Name.Name -> Can.FieldUpdate -> IO ( UF.Variable, Type, Constraint )
constrainUpdateField rtv region field (Can.FieldUpdate _ expr) =
    mkFlexVar
        |> IO.bind
            (\var ->
                let
                    tipe =
                        VarN var
                in
                constrain rtv expr (FromContext region (RecordUpdateValue field) tipe)
                    |> IO.fmap (\con -> ( var, tipe, con ))
            )



-- CONSTRAIN TUPLE


constrainTuple : RTV -> A.Region -> Can.Expr -> Can.Expr -> Maybe Can.Expr -> Expected Type -> IO Constraint
constrainTuple rtv region a b maybeC expected =
    mkFlexVar
        |> IO.bind
            (\aVar ->
                mkFlexVar
                    |> IO.bind
                        (\bVar ->
                            let
                                aType =
                                    VarN aVar

                                bType =
                                    VarN bVar
                            in
                            constrain rtv a (NoExpectation aType)
                                |> IO.bind
                                    (\aCon ->
                                        constrain rtv b (NoExpectation bType)
                                            |> IO.bind
                                                (\bCon ->
                                                    case maybeC of
                                                        Nothing ->
                                                            let
                                                                tupleType =
                                                                    TupleN aType bType Nothing

                                                                tupleCon =
                                                                    CEqual region Tuple tupleType expected
                                                            in
                                                            IO.pure (exists [ aVar, bVar ] (CAnd [ aCon, bCon, tupleCon ]))

                                                        Just c ->
                                                            mkFlexVar
                                                                |> IO.bind
                                                                    (\cVar ->
                                                                        let
                                                                            cType =
                                                                                VarN cVar
                                                                        in
                                                                        constrain rtv c (NoExpectation cType)
                                                                            |> IO.fmap
                                                                                (\cCon ->
                                                                                    let
                                                                                        tupleType =
                                                                                            TupleN aType bType (Just cType)

                                                                                        tupleCon =
                                                                                            CEqual region Tuple tupleType expected
                                                                                    in
                                                                                    exists [ aVar, bVar, cVar ] (CAnd [ aCon, bCon, cCon, tupleCon ])
                                                                                )
                                                                    )
                                                )
                                    )
                        )
            )



-- CONSTRAIN SHADER


constrainShader : A.Region -> Shader.Types -> Expected Type -> IO Constraint
constrainShader region (Shader.Types attributes uniforms varyings) expected =
    mkFlexVar
        |> IO.bind
            (\attrVar ->
                mkFlexVar
                    |> IO.fmap
                        (\unifVar ->
                            let
                                attrType =
                                    VarN attrVar

                                unifType =
                                    VarN unifVar

                                shaderType =
                                    AppN ModuleName.webgl
                                        Name.shader
                                        [ toShaderRecord attributes attrType
                                        , toShaderRecord uniforms unifType
                                        , toShaderRecord varyings EmptyRecordN
                                        ]
                            in
                            exists [ attrVar, unifVar ] (CEqual region Shader shaderType expected)
                        )
            )


toShaderRecord : Dict Name.Name Shader.Type -> Type -> Type
toShaderRecord types baseRecType =
    if Dict.isEmpty types then
        baseRecType

    else
        RecordN (Dict.map (\_ -> glToType) types) baseRecType


glToType : Shader.Type -> Type
glToType glType =
    case glType of
        Shader.V2 ->
            Type.vec2

        Shader.V3 ->
            Type.vec3

        Shader.V4 ->
            Type.vec4

        Shader.M4 ->
            Type.mat4

        Shader.Int ->
            Type.int

        Shader.Float ->
            Type.float

        Shader.Texture ->
            Type.texture



-- CONSTRAIN DESTRUCTURES


constrainDestruct : RTV -> A.Region -> Can.Pattern -> Can.Expr -> Constraint -> IO Constraint
constrainDestruct rtv region pattern expr bodyCon =
    mkFlexVar
        |> IO.bind
            (\patternVar ->
                let
                    patternType =
                        VarN patternVar
                in
                Pattern.add pattern (PNoExpectation patternType) Pattern.emptyState
                    |> IO.bind
                        (\(Pattern.State headers pvars revCons) ->
                            constrain rtv expr (FromContext region Destructure patternType)
                                |> IO.fmap
                                    (\exprCon ->
                                        CLet [] (patternVar :: pvars) headers (CAnd (List.reverse (exprCon :: revCons))) bodyCon
                                    )
                        )
            )



-- CONSTRAIN DEF


constrainDef : RTV -> Can.Def -> Constraint -> IO Constraint
constrainDef rtv def bodyCon =
    case def of
        Can.Def (A.At region name) args expr ->
            constrainArgs args
                |> IO.bind
                    (\(Args vars tipe resultType (Pattern.State headers pvars revCons)) ->
                        constrain rtv expr (NoExpectation resultType)
                            |> IO.fmap
                                (\exprCon ->
                                    CLet []
                                        vars
                                        (Dict.singleton name (A.At region tipe))
                                        (CLet []
                                            pvars
                                            headers
                                            (CAnd (List.reverse revCons))
                                            exprCon
                                        )
                                        bodyCon
                                )
                    )

        Can.TypedDef (A.At region name) freeVars typedArgs expr srcResultType ->
            let
                newNames =
                    Dict.diff freeVars rtv
            in
            Utils.mapTraverseWithKey compare (\n _ -> nameToRigid n) newNames
                |> IO.bind
                    (\newRigids ->
                        let
                            newRtv =
                                Dict.union compare rtv (Dict.map (\_ -> VarN) newRigids)
                        in
                        constrainTypedArgs newRtv name typedArgs srcResultType
                            |> IO.bind
                                (\(TypedArgs tipe resultType (Pattern.State headers pvars revCons)) ->
                                    let
                                        expected =
                                            FromAnnotation name (List.length typedArgs) TypedBody resultType
                                    in
                                    constrain newRtv expr expected
                                        |> IO.fmap
                                            (\exprCon ->
                                                CLet (Dict.values newRigids)
                                                    []
                                                    (Dict.singleton name (A.At region tipe))
                                                    (CLet []
                                                        pvars
                                                        headers
                                                        (CAnd (List.reverse revCons))
                                                        exprCon
                                                    )
                                                    bodyCon
                                            )
                                )
                    )



-- CONSTRAIN RECURSIVE DEFS


type Info
    = Info (List UF.Variable) (List Constraint) (Dict Name (A.Located Type))


emptyInfo : Info
emptyInfo =
    Info [] [] Dict.empty


constrainRecursiveDefs : RTV -> List Can.Def -> Constraint -> IO Constraint
constrainRecursiveDefs rtv defs bodyCon =
    recDefsHelp rtv defs bodyCon emptyInfo emptyInfo


recDefsHelp : RTV -> List Can.Def -> Constraint -> Info -> Info -> IO Constraint
recDefsHelp rtv defs bodyCon rigidInfo flexInfo =
    case defs of
        [] ->
            let
                (Info rigidVars rigidCons rigidHeaders) =
                    rigidInfo

                (Info flexVars flexCons flexHeaders) =
                    flexInfo
            in
            IO.pure <|
                CLet rigidVars [] rigidHeaders CTrue <|
                    CLet [] flexVars flexHeaders (CLet [] [] flexHeaders CTrue (CAnd flexCons)) <|
                        CAnd [ CAnd rigidCons, bodyCon ]

        def :: otherDefs ->
            case def of
                Can.Def (A.At region name) args expr ->
                    let
                        (Info flexVars flexCons flexHeaders) =
                            flexInfo
                    in
                    argsHelp args (Pattern.State Dict.empty flexVars [])
                        |> IO.bind
                            (\(Args newFlexVars tipe resultType (Pattern.State headers pvars revCons)) ->
                                constrain rtv expr (NoExpectation resultType)
                                    |> IO.bind
                                        (\exprCon ->
                                            let
                                                defCon =
                                                    CLet []
                                                        pvars
                                                        headers
                                                        (CAnd (List.reverse revCons))
                                                        exprCon
                                            in
                                            recDefsHelp rtv otherDefs bodyCon rigidInfo <|
                                                Info newFlexVars
                                                    (defCon :: flexCons)
                                                    (Dict.insert compare name (A.At region tipe) flexHeaders)
                                        )
                            )

                Can.TypedDef (A.At region name) freeVars typedArgs expr srcResultType ->
                    let
                        newNames =
                            Dict.diff freeVars rtv
                    in
                    Utils.mapTraverseWithKey compare (\n _ -> nameToRigid n) newNames
                        |> IO.bind
                            (\newRigids ->
                                let
                                    newRtv =
                                        Dict.union compare rtv (Dict.map (\_ -> VarN) newRigids)
                                in
                                constrainTypedArgs newRtv name typedArgs srcResultType
                                    |> IO.bind
                                        (\(TypedArgs tipe resultType (Pattern.State headers pvars revCons)) ->
                                            constrain newRtv expr (FromAnnotation name (List.length typedArgs) TypedBody resultType)
                                                |> IO.bind
                                                    (\exprCon ->
                                                        let
                                                            defCon =
                                                                CLet []
                                                                    pvars
                                                                    headers
                                                                    (CAnd (List.reverse revCons))
                                                                    exprCon

                                                            (Info rigidVars rigidCons rigidHeaders) =
                                                                rigidInfo
                                                        in
                                                        recDefsHelp rtv
                                                            otherDefs
                                                            bodyCon
                                                            (Info
                                                                (Dict.foldr (\_ -> (::)) rigidVars newRigids)
                                                                (CLet (Dict.values newRigids) [] Dict.empty defCon CTrue :: rigidCons)
                                                                (Dict.insert compare name (A.At region tipe) rigidHeaders)
                                                            )
                                                            flexInfo
                                                    )
                                        )
                            )



-- CONSTRAIN ARGS


type Args
    = Args (List UF.Variable) Type Type Pattern.State


constrainArgs : List Can.Pattern -> IO Args
constrainArgs args =
    argsHelp args Pattern.emptyState


argsHelp : List Can.Pattern -> Pattern.State -> IO Args
argsHelp args state =
    case args of
        [] ->
            mkFlexVar
                |> IO.fmap
                    (\resultVar ->
                        let
                            resultType =
                                VarN resultVar
                        in
                        Args [ resultVar ] resultType resultType state
                    )

        pattern :: otherArgs ->
            mkFlexVar
                |> IO.bind
                    (\argVar ->
                        let
                            argType =
                                VarN argVar
                        in
                        Pattern.add pattern (PNoExpectation argType) state
                            |> IO.bind (argsHelp otherArgs)
                            |> IO.fmap
                                (\(Args vars tipe result newState) ->
                                    Args (argVar :: vars) (FunN argType tipe) result newState
                                )
                    )



-- CONSTRAIN TYPED ARGS


type TypedArgs
    = TypedArgs Type Type Pattern.State


constrainTypedArgs : Dict Name.Name Type -> Name.Name -> List ( Can.Pattern, Can.Type ) -> Can.Type -> IO TypedArgs
constrainTypedArgs rtv name args srcResultType =
    typedArgsHelp rtv name Index.first args srcResultType Pattern.emptyState


typedArgsHelp : Dict Name.Name Type -> Name.Name -> Index.ZeroBased -> List ( Can.Pattern, Can.Type ) -> Can.Type -> Pattern.State -> IO TypedArgs
typedArgsHelp rtv name index args srcResultType state =
    case args of
        [] ->
            Instantiate.fromSrcType rtv srcResultType
                |> IO.fmap
                    (\resultType ->
                        TypedArgs resultType resultType state
                    )

        ( (A.At region _) as pattern, srcType ) :: otherArgs ->
            Instantiate.fromSrcType rtv srcType
                |> IO.bind
                    (\argType ->
                        let
                            expected =
                                PFromContext region (PTypedArg name index) argType
                        in
                        Pattern.add pattern expected state
                            |> IO.bind (typedArgsHelp rtv name (Index.next index) otherArgs srcResultType)
                            |> IO.fmap
                                (\(TypedArgs tipe resultType newState) ->
                                    TypedArgs (FunN argType tipe) resultType newState
                                )
                    )
