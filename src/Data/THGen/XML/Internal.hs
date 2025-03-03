{-# LANGUAGE CPP                    #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE UndecidableInstances   #-}

module Data.THGen.XML.Internal where

import           Control.Category                     ((>>>))
import           Control.DeepSeq
import           Control.Lens                         hiding (Strict, enum,
                                                       repeated, (&))
import           Control.Lens.Internal.FieldTH        (makeFieldOpticsForDec)
import qualified Data.Char                            as C
import           Data.Function                        (on)
import qualified Data.List                            as L
import           Data.List.NonEmpty                   (NonEmpty)
import           Data.Maybe                           (mapMaybe, maybeToList)
import           Data.String
import           Data.THGen.Compat                    as THC
import           Data.THGen.Enum
import qualified Data.Text                            as T
import           GHC.Generics                         (Generic)
import           Language.Haskell.TH                  as TH hiding (Strict)
import qualified Language.Haskell.TH.Syntax           as TH
import           Prelude                              hiding ((*), (+), (^))
import qualified Text.XML                             as X
import           Text.XML.DOM.Parser                  hiding (parseContent)
import           Text.XML.DOM.Parser.Internal.Content
import           Text.XML.ParentAttributes
import qualified Text.XML.Writer                      as XW

data ParserMode
  = Strict
  | Lenient

data GenType
  = Parser
  | Generator
  | ParserAndGenerator
  | LenientParser
  | LenientParserAndGenerator

isLenientType :: GenType -> Bool
isLenientType = \case
  LenientParser             -> True
  LenientParserAndGenerator -> True
  _                         -> False

data XmlFieldPlural
  = XmlFieldPluralMandatory  -- Occurs exactly 1 time (Identity)
  | XmlFieldPluralOptional   -- Occurs 0 or 1 times (Maybe)
  | XmlFieldPluralRepeated   -- Occurs 0 or more times (List)
  | XmlFieldPluralMultiplied -- Occurs 1 or more times (NonEmpty)

data XmlAttributePlural
  = XmlAttributePluralMandatory -- Occurs exactly 1 time (Identity)
  | XmlAttributePluralOptional  -- Occurs 0 or 1 times (Maybe)

data PrefixName = PrefixName String String

data IsoXmlDescPreField = IsoXmlDescPreField String TH.TypeQ

data IsoXmlDescPreAttribute = IsoXmlDescPreAttribute String TH.TypeQ

data IsoXmlDescPreContent = IsoXmlDescPreContent String TH.TypeQ

data IsoXmlDescField = IsoXmlDescField XmlFieldPlural String TH.TypeQ

data IsoXmlDescAttribute = IsoXmlDescAttribute XmlAttributePlural String TH.TypeQ

data IsoXmlDescContent = IsoXmlDescContent String TH.TypeQ

data IsoXmlDescRecordPart
  = IsoXmlDescRecordField     IsoXmlDescField
  | IsoXmlDescRecordAttribute IsoXmlDescAttribute
  | IsoXmlDescRecordContent   IsoXmlDescContent

makePrisms ''IsoXmlDescRecordPart

data IsoXmlDescRecord = IsoXmlDescRecord GenType [IsoXmlDescRecordPart]

makePrisms ''IsoXmlDescRecord

data ExhaustivenessName = ExhaustivenessName String Exhaustiveness

newtype IsoXmlDescEnumCon
  = IsoXmlDescEnumCon { unIsoXmlDescEnumCon :: String }

instance IsString IsoXmlDescEnumCon where
  fromString = IsoXmlDescEnumCon

data IsoXmlDescEnum = IsoXmlDescEnum GenType [IsoXmlDescEnumCon]

makePrisms ''IsoXmlDescEnum

appendField
  :: XmlFieldPlural
  -> IsoXmlDescRecord
  -> IsoXmlDescPreField
  -> IsoXmlDescRecord
appendField plural (IsoXmlDescRecord genType fields) (IsoXmlDescPreField name ty) =
  let xfield = IsoXmlDescRecordField $ IsoXmlDescField plural name ty
  in IsoXmlDescRecord genType (xfield:fields)

appendAttribute
  :: XmlAttributePlural
  -> IsoXmlDescRecord
  -> IsoXmlDescPreAttribute
  -> IsoXmlDescRecord
appendAttribute plural (IsoXmlDescRecord genType fields) (IsoXmlDescPreAttribute name ty) =
  let xattribute = IsoXmlDescRecordAttribute $ IsoXmlDescAttribute plural name ty
  in IsoXmlDescRecord genType (xattribute:fields)

appendContent
  :: IsoXmlDescRecord
  -> IsoXmlDescPreContent
  -> IsoXmlDescRecord
appendContent (IsoXmlDescRecord genType fields) (IsoXmlDescPreContent name ty) =
  let xcontent = IsoXmlDescRecordContent $ IsoXmlDescContent name ty
  in IsoXmlDescRecord genType (xcontent:fields)

(!), (?), (*), (+) :: IsoXmlDescRecord -> IsoXmlDescPreField -> IsoXmlDescRecord
(!) = appendField XmlFieldPluralMandatory
(?) = appendField XmlFieldPluralOptional
(*) = appendField XmlFieldPluralRepeated
(+) = appendField XmlFieldPluralMultiplied

(!%), (?%) :: IsoXmlDescRecord -> IsoXmlDescPreAttribute -> IsoXmlDescRecord
(!%) = appendAttribute XmlAttributePluralMandatory
(?%) = appendAttribute XmlAttributePluralOptional

(^) :: IsoXmlDescRecord -> IsoXmlDescPreContent -> IsoXmlDescRecord
(^) = appendContent

infixl 2 !
infixl 2 ?
infixl 2 *
infixl 2 +
infixl 2 !%
infixl 2 ?%
infixl 2 ^

appendEnumCon :: IsoXmlDescEnum -> IsoXmlDescEnumCon -> IsoXmlDescEnum
appendEnumCon (IsoXmlDescEnum genType enumCons) xenumcon =
  IsoXmlDescEnum genType (xenumcon:enumCons)

(&) :: IsoXmlDescEnum -> IsoXmlDescEnumCon -> IsoXmlDescEnum
(&) = appendEnumCon

infixl 2 &

class Description name desc | desc -> name where
  (=:=) :: name -> desc -> TH.DecsQ

infix 0 =:=

recordPartName :: Traversal' IsoXmlDescRecordPart String
recordPartName f = \case
  (IsoXmlDescRecordField (IsoXmlDescField pl name ty)) ->
    (\n -> IsoXmlDescRecordField (IsoXmlDescField pl n ty)) <$> f name
  (IsoXmlDescRecordAttribute (IsoXmlDescAttribute pl name ty)) ->
    (\n -> IsoXmlDescRecordAttribute (IsoXmlDescAttribute pl n ty)) <$> f name
  (IsoXmlDescRecordContent (IsoXmlDescContent name ty)) ->
    (\n -> IsoXmlDescRecordContent (IsoXmlDescContent n ty)) <$> f name

attributeName :: Traversal' IsoXmlDescAttribute String
attributeName f (IsoXmlDescAttribute pl name ty) =
  (\n -> IsoXmlDescAttribute pl n ty) <$> f name

fieldAttrSameName :: IsoXmlDescRecordPart -> IsoXmlDescRecordPart -> Bool
fieldAttrSameName = (==)
  `on` over _head C.toUpper
  `on` view recordPartName

compareName :: IsoXmlDescRecordPart -> IsoXmlDescRecordPart -> Ordering
compareName = compare `on` view recordPartName

groupedByName :: Iso' [IsoXmlDescRecordPart] [[(Int, IsoXmlDescRecordPart)]]
groupedByName = iso
  ( -- attach indices to preserve the original order
    zip [1..] >>>
    L.sortBy (compareName `on` snd) >>>
    L.groupBy (fieldAttrSameName `on` snd)
  )
  ( L.concat >>>
    -- restore the original order
    L.sortBy (compare `on` fst) >>>
    -- remove indices
    fmap snd
  )

nonUnique :: Traversal' [IsoXmlDescRecordPart] IsoXmlDescRecordPart
nonUnique = groupedByName
  . traversed
  . filtered (length >>> (>1))
  . traversed
  . _2

addAttrPostfixWhereClashes :: [IsoXmlDescRecordPart] -> [(IsoXmlDescRecordPart, String)]
addAttrPostfixWhereClashes rps = zip
  rps
  (rps' ^.. traversed . recordPartName)
  where
    rps' = nonUnique
      . _IsoXmlDescRecordAttribute
      . attributeName <>~ "Attr"
      $ rps

instance Description PrefixName IsoXmlDescRecord where
  prefixName =:= (IsoXmlDescRecord genType descRecordParts) =
    isoXmlGenerateDatatype
    genType
    prefixName
    (reverse $ addAttrPostfixWhereClashes descRecordParts)

record :: GenType -> IsoXmlDescRecord
record gt = IsoXmlDescRecord gt []

enum :: GenType -> IsoXmlDescEnum
enum gt = IsoXmlDescEnum gt []

instance Description ExhaustivenessName IsoXmlDescEnum where
  exhaustivenessName =:= (IsoXmlDescEnum genType descEnumCons) =
    isoXmlGenerateEnum genType exhaustivenessName (reverse descEnumCons)

instance IsString (TH.TypeQ -> IsoXmlDescPreField) where
  fromString = IsoXmlDescPreField

instance IsString IsoXmlDescPreField where
  fromString name = IsoXmlDescPreField name ty
    where
      ty = (TH.conT . TH.mkName) ("Xml" ++ over _head C.toUpper (xmlLocalName name))

instance IsString (TH.TypeQ -> IsoXmlDescPreAttribute) where
  fromString = IsoXmlDescPreAttribute

instance IsString (TH.TypeQ -> IsoXmlDescPreContent) where
  fromString = IsoXmlDescPreContent

instance IsString IsoXmlDescPreAttribute where
  fromString name = IsoXmlDescPreAttribute name ty
    where
      ty = (TH.conT . TH.mkName) ("Xml" ++ over _head C.toUpper name)

instance IsString IsoXmlDescPreContent where
  fromString name = IsoXmlDescPreContent name ty
    where
      ty = (TH.conT . TH.mkName) ("Xml" ++ over _head C.toUpper name)

instance s ~ String => IsString (s -> PrefixName) where
  fromString = PrefixName

instance IsString PrefixName where
  fromString strName = PrefixName strName (makeNamePrefix strName)

instance e ~ Exhaustiveness => IsString (e -> ExhaustivenessName) where
  fromString = ExhaustivenessName

instance IsString ExhaustivenessName where
  fromString strName = ExhaustivenessName strName NonExhaustive

makeNamePrefix :: String -> String
makeNamePrefix = map C.toLower . filter (\c -> C.isUpper c || C.isDigit c)

funSimple :: TH.Name -> TH.ExpQ -> TH.DecQ
funSimple name body = TH.funD name [ TH.clause [] (TH.normalB body) [] ]

isoXmlGenerateEnum
  :: GenType
  -> ExhaustivenessName
  -> [IsoXmlDescEnumCon]
  -> TH.DecsQ
isoXmlGenerateEnum genType (ExhaustivenessName strName' exh) enumCons = do
  let
    strName  = "Xml" ++ strName'
    strVals  = map unIsoXmlDescEnumCon enumCons
    enumDesc = EnumDesc exh strName strVals
    name     = TH.mkName strName
  enumDecls <- enumGenerate enumDesc
  let
    genToXmlInst = do
      TH.instanceD
        (return [])
        [t|XW.ToXML $(TH.conT name)|]
        [funSimple 'XW.toXML [e|XW.toXML . T.pack . show|]]
    genToXmlAttributeInst = do
      TH.instanceD
        (return [])
        [t|ToXmlAttribute $(TH.conT name)|]
        [funSimple 'toXmlAttribute [e|T.pack . show|]]
    genFromDomInst mode = do
      TH.instanceD
        (return [])
        [t|FromDom $(TH.conT name)|]
        [case mode of
          Strict -> funSimple 'fromDom [e|parseContent readContent|]
          Lenient -> funSimple 'fromDom [e|ignoreBlank $ parseContent readContent|]
        ]
    genFromAttributeInst = do
      TH.instanceD
        (return [])
        [t|FromAttribute $(TH.conT name)|]
        [funSimple 'fromAttribute [e|readContent|]]
  case genType of
    Generator -> do
      toXmlInst <- genToXmlInst
      toXmlAttributeInst <- genToXmlAttributeInst
      return $ enumDecls ++ [toXmlInst, toXmlAttributeInst]
    Parser -> do
      fromDomInst <- genFromDomInst Strict
      fromAttributeInst <- genFromAttributeInst
      return $ enumDecls ++ [fromDomInst, fromAttributeInst]
    LenientParser -> do
      fromDomInst <- genFromDomInst Lenient
      fromAttributeInst <- genFromAttributeInst
      return $ enumDecls ++ [fromDomInst, fromAttributeInst]
    ParserAndGenerator -> do
      toXmlInst <- genToXmlInst
      toXmlAttributeInst <- genToXmlAttributeInst
      fromDomInst <- genFromDomInst Strict
      fromAttributeInst <- genFromAttributeInst
      return $ enumDecls ++ [toXmlInst, toXmlAttributeInst,
        fromDomInst, fromAttributeInst]
    LenientParserAndGenerator -> do
      toXmlInst <- genToXmlInst
      toXmlAttributeInst <- genToXmlAttributeInst
      fromDomInst <- genFromDomInst Lenient
      fromAttributeInst <- genFromAttributeInst
      return $ enumDecls ++ [toXmlInst, toXmlAttributeInst,
        fromDomInst, fromAttributeInst]

isoXmlGenerateDatatype :: GenType -> PrefixName -> [(IsoXmlDescRecordPart, String)] -> TH.DecsQ
isoXmlGenerateDatatype genType (PrefixName strName' strPrefix') descRecordParts = do
  let
    isNewtype     = length descRecordParts == 1
    strName       = "Xml" ++ strName'
    strPrefix     = "x" ++ strPrefix'
    name          = TH.mkName strName
    fieldName str = "_" ++ strPrefix ++ over _head C.toUpper str
  termDecl <- do
    let
      fields = do
        descRecordPart <- descRecordParts
        return $ case descRecordPart of
          (IsoXmlDescRecordField descField, _) ->
            let
              IsoXmlDescField fieldPlural rawName fieldType = descField
              fieldStrName = xmlLocalName rawName
              fName = TH.mkName (fieldName fieldStrName)
              fType' = case fieldPlural of
                XmlFieldPluralMandatory  -> fieldType
                XmlFieldPluralOptional   -> [t| Maybe $fieldType |]
                XmlFieldPluralRepeated   -> [t| [$fieldType] |]
                XmlFieldPluralMultiplied -> [t| NonEmpty $fieldType |]
              fType = if isLenientType genType
                then [t| Maybe $fType' |]
                else fType'
            in if isNewtype
              then THC.varStrictType fName (THC.nonStrictType fType)
              else THC.varStrictType fName (THC.strictType fType)
          (IsoXmlDescRecordAttribute descAttribute, attributeFieldName) ->
            let
              IsoXmlDescAttribute
                attributePlural _ attributeType = descAttribute
              fName = TH.mkName (fieldName attributeFieldName)
              fType = case attributePlural of
                XmlAttributePluralMandatory -> attributeType
                XmlAttributePluralOptional  -> [t| Maybe $attributeType |]
            in if isNewtype
              then THC.varStrictType fName (THC.nonStrictType fType)
              else THC.varStrictType fName (THC.strictType fType)
          (IsoXmlDescRecordContent descContent, _) ->
            let
              IsoXmlDescContent contentStrName contentType = descContent
              fName = TH.mkName (fieldName contentStrName)
              fType = contentType
            in if isNewtype
              then THC.varStrictType fName (THC.nonStrictType fType)
              else THC.varStrictType fName (THC.strictType fType)
    if isNewtype
    -- generate a newtype instead to do less allocations later
    then THC.newtypeD name (TH.recC name fields) [''Eq, ''Show, ''Generic]
    else THC.dataD name [TH.recC name fields] [''Eq, ''Show, ''Generic]
  lensDecls <- makeFieldOpticsForDec lensRules termDecl
  nfDataInst <- do
    TH.instanceD
      (return [])
      [t|NFData $(TH.conT name)|]
      [ ]

  let
    genFromDomInst mode = do
      let
        exprHeader      = [e|pure $(TH.conE name)|]
        exprRecordParts = do
          descRecordPart <- fmap fst descRecordParts
          return $ case descRecordPart of
            IsoXmlDescRecordField descField ->
              let
                IsoXmlDescField fieldPlural rawName _ = descField
                fieldStrName     = xmlLocalName rawName
                exprFieldStrName = TH.litE (TH.stringL fieldStrName)
                fieldParse       = case fieldPlural of
                  XmlFieldPluralMandatory -> [e|inElem|]
                  _                       -> [e|inElemTrav|]
              in case mode of
                Strict -> [e|$fieldParse $exprFieldStrName fromDom|]
                Lenient -> [e|$fieldParse $exprFieldStrName (ignoreBlank fromDom)|]
            IsoXmlDescRecordAttribute descAttribute ->
              let
                IsoXmlDescAttribute attributePlural attributeStrName _ = descAttribute
                exprAttributeStrName = TH.litE (TH.stringL attributeStrName)
                attributeParse       = case attributePlural of
                  XmlAttributePluralMandatory -> [e|parseAttribute|]
                  XmlAttributePluralOptional  -> [e|parseAttributeMaybe|]
              in
                [e|$attributeParse $exprAttributeStrName fromAttribute|]
            IsoXmlDescRecordContent _ -> [e|parseContent fromAttribute|]
        fromDomExpr = foldl (\e fe -> [e| $e <*> $fe |]) exprHeader exprRecordParts
      TH.instanceD
        (return [])
        [t|FromDom $(TH.conT name)|]
        [ funSimple 'fromDom fromDomExpr ]

    genToXmlInst = do
      objName <- TH.newName strPrefix
      let
        exprFields = do
          descRecordPart <- fmap fst descRecordParts
          case descRecordPart of
            IsoXmlDescRecordField (IsoXmlDescField fieldPlural rawName _) -> do
              let
                fieldStrName          = xmlLocalName rawName
                fName                 = TH.mkName (fieldName fieldStrName)
                exprFieldStrName      = TH.lift $
                  case xmlPrefix rawName of
                    Nothing -> fieldStrName
                    Just pref ->
                      case xmlNamespace rawName of
                        Nothing -> pref <> ":" <> fieldStrName
                        Just _  -> fieldStrName
                exprFieldStrNamespace = TH.lift $ xmlNamespace rawName
                exprFieldFullName = [e|
                    X.Name $exprFieldStrName $exprFieldStrNamespace Nothing
                  |]
                exprForField          = case fieldPlural of
                  XmlFieldPluralMandatory -> [e|id|]
                  _                       -> [e|traverse|]
                exprFieldValue   = [e|$(TH.varE fName) $(TH.varE objName)|]
                exprFieldRender  =
                  [e|(\a ->
                      XW.elementA $exprFieldFullName (toXmlParentAttributes a) a)|]
              return [e|$exprForField $exprFieldRender $exprFieldValue|]
            IsoXmlDescRecordContent (IsoXmlDescContent rawName _) -> do
              let
                fieldStrName     = xmlLocalName rawName
                fName            = TH.mkName (fieldName fieldStrName)
                exprFieldValue   = [e|$(TH.varE fName) $(TH.varE objName)|]
              return [e|XW.content . toXmlAttribute $ $exprFieldValue|]
            _ -> []
        toXmlExpr
          = TH.lamE [if null exprFields then TH.wildP else TH.varP objName]
          $ foldr (\fe e -> [e|$fe *> $e|]) [e|return ()|] exprFields
      TH.instanceD
        (return [])
        [t|XW.ToXML $(TH.conT name)|]
        [funSimple 'XW.toXML toXmlExpr]
    genToXmlParentAttributeInst = do
      objName <- TH.newName strPrefix
      let
        exprAttributes            = do
          descRecordPart <- descRecordParts
          (IsoXmlDescAttribute attributePlural attributeStrName _, attributeFieldName) <-
            maybeToList $ case descRecordPart of
              (IsoXmlDescRecordAttribute descAttribute, attributeFieldName) -> Just (descAttribute, attributeFieldName)
              _                                       -> Nothing
          let
            fName           = TH.mkName (fieldName attributeFieldName)
            exprAttrStrName = TH.litE (TH.stringL attributeStrName)
            exprAttrValue   = [e|$(TH.varE fName) $(TH.varE objName)|]
            exprAttrWrap    = case attributePlural of
              XmlAttributePluralMandatory -> [e|Just . toXmlAttribute|]
              XmlAttributePluralOptional  -> [e|fmap toXmlAttribute|]
          return [e|($exprAttrStrName, $exprAttrWrap $exprAttrValue)|]
        toXmlParentAttributesExpr
          = TH.lamE [if null exprAttributes then TH.wildP else TH.varP objName]
          $ [e|mapMaybe distribPair $(TH.listE exprAttributes)|]
#if __GLASGOW_HASKELL__ < 800
      TH.instanceD
#else
      TH.instanceWithOverlapD (Just TH.Overlapping)
#endif
        (return [])
        [t|ToXmlParentAttributes $(TH.conT name)|]
        [funSimple 'toXmlParentAttributes toXmlParentAttributesExpr]

  case genType of
    Generator -> do
      toXmlInst <- genToXmlInst
      toXmlParentAttributesInst <- genToXmlParentAttributeInst
      return $ [termDecl] ++ lensDecls ++
        [toXmlInst, toXmlParentAttributesInst, nfDataInst]
    Parser -> do
      fromDomInst <- genFromDomInst Strict
      return $ [termDecl] ++ lensDecls ++ [fromDomInst, nfDataInst]
    LenientParser -> do
      fromDomInst <- genFromDomInst Lenient
      return $ [termDecl] ++ lensDecls ++ [fromDomInst, nfDataInst]
    ParserAndGenerator -> do
      toXmlInst <- genToXmlInst
      toXmlParentAttributesInst <- genToXmlParentAttributeInst
      fromDomInst <- genFromDomInst Strict
      return $ [termDecl] ++ lensDecls ++
        [fromDomInst, toXmlInst, toXmlParentAttributesInst, nfDataInst]
    LenientParserAndGenerator -> do
      toXmlInst <- genToXmlInst
      toXmlParentAttributesInst <- genToXmlParentAttributeInst
      fromDomInst <- genFromDomInst Lenient
      return $ [termDecl] ++ lensDecls ++
        [fromDomInst, toXmlInst, toXmlParentAttributesInst, nfDataInst]

distribPair :: Functor f => (a, f b) -> f (a, b)
distribPair (a, fb) = (a,) <$> fb

-- | Get a local part of (possibly) fully qualified 'X.Name':
--
-- >>> xmlLocalName "{http://example.com/ns/my-namespace}my-name"
-- "my-name"
xmlLocalName :: String -> String
xmlLocalName = dropNamespace . T.unpack . X.nameLocalName . fromString
  where
    dropNamespace :: String -> String
    dropNamespace name' = case dropWhile (/= ':') name' of
      []         -> name'
      _ : name'' -> name''

xmlNamespace :: String -> Maybe String
xmlNamespace = fmap T.unpack . X.nameNamespace  . fromString

xmlPrefix :: String -> Maybe String
xmlPrefix s = if s == mbPrefix then Nothing else Just mbPrefix
  where
    mbPrefix = takeWhile (':' /=) $ T.unpack $ X.nameLocalName $ fromString s
