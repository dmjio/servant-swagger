{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ConstraintKinds #-}
#if __GLASGOW_HASKELL__ >= 710
#define OVERLAPPABLE_ {-# OVERLAPPABLE #-}
#else
{-# LANGUAGE OverlappingInstances #-}
#define OVERLAPPABLE_
#endif
module Servant.Swagger.Internal where

import Control.Lens
import Data.Aeson
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap
import Data.Monoid
import Data.Proxy
import qualified Data.Swagger as Swagger
import Data.Swagger hiding (Header)
import Data.Swagger.Declare
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.TypeLits
import Network.HTTP.Media (MediaType)
import Servant.API

import Servant.Swagger.Internal.TypeLevel.API

-- | Generate a Swagger specification for a servant API.
--
-- To generate Swagger specification, your data types need
-- @'ToParamSchema'@ and/or @'ToSchema'@ instances.
--
-- @'ToParamSchema'@ is used for @'Capture'@, @'QueryParam'@ and @'Header'@.
-- @'ToSchema'@ is used for @'ReqBody'@ and response data types.
--
-- You can easily derive those instances via @Generic@.
-- For more information, refer to <http://hackage.haskell.org/package/swagger2/docs/Data-Swagger.html swagger2 documentation>.
--
-- Example:
--
-- @
-- newtype Username = Username String deriving (Generic, ToText)
--
-- instance ToParamSchema Username
--
-- data User = User
--   { username :: Username
--   , fullname :: String
--   } deriving (Generic)
--
-- instance ToJSON User
-- instance ToSchema User
--
-- type MyAPI = QueryParam "username" Username :> Get '[JSON] User
--
-- mySwagger :: Swagger
-- mySwagger = toSwagger (Proxy :: Proxy MyAPI)
-- @
class HasSwagger api where
  -- | Generate a Swagger specification for a servant API.
  toSwagger :: Proxy api -> Swagger

instance HasSwagger Raw where
  toSwagger _ = mempty & paths . at "/" ?~ mempty

-- | All operations of sub API.
-- This is similar to @'operationsOf'@ but ensures that operations
-- indeed belong to the API at compile time.
subOperations :: (IsSubAPI sub api, HasSwagger sub) =>
  Proxy sub     -- ^ Part of a servant API.
  -> Proxy api  -- ^ The whole servant API.
  -> Traversal' Swagger Operation
subOperations sub _ = operationsOf (toSwagger sub)

#if MIN_VERSION_servant(0,5,0)
-- | Make an singleton Swagger spec (with only one endpoint).
mkEndpoint :: forall a cs hs proxy method status.
  (ToSchema a, AllAccept cs, AllToResponseHeader hs, SwaggerMethod method, KnownNat status)
  => FilePath                                     -- ^ Endpoint path.
  -> proxy (Verb method status cs (Headers hs a)) -- ^ Method, content-types, headers and response.
  -> Swagger
mkEndpoint path proxy
  = mkEndpointWithSchemaRef (Just ref) path proxy
      & definitions .~ defs
  where
    (defs, ref) = runDeclare (declareSchemaRef (Proxy :: Proxy a)) mempty

-- | Like @'mkEndpoint'@ but with explicit schema reference.
-- Unlike @'mkEndpoint'@ this function does not update @'definitions'@.
mkEndpointWithSchemaRef :: forall cs hs proxy method status a.
  (AllAccept cs, AllToResponseHeader hs, SwaggerMethod method, KnownNat status)
  => Maybe (Referenced Schema)
  -> FilePath
  -> proxy (Verb method status cs (Headers hs a))
  -> Swagger
mkEndpointWithSchemaRef mref path _ = mempty
  & paths.at path ?~
    (mempty & method ?~ (mempty
      & produces ?~ MimeList contentTypes
      & at code ?~ Inline (mempty
            & schema  .~ mref
            & headers .~ responseHeaders)))
  where
    method          = swaggerMethod (Proxy :: Proxy method)
    code            = fromIntegral (natVal (Proxy :: Proxy status))
    contentTypes    = allContentType (Proxy :: Proxy cs)
    responseHeaders = toAllResponseHeaders (Proxy :: Proxy hs)
#else
mkEndpoint :: forall a cs hs proxy _verb. (ToSchema a, AllAccept cs, AllToResponseHeader hs)
  => FilePath
  -> Lens' PathItem (Maybe Operation)
  -> HttpStatusCode
  -> proxy (_verb cs (Headers hs a))
  -> Swagger
mkEndpoint path verb code proxy
  = mkEndpointWithSchemaRef (Just ref) path verb code proxy
      & definitions .~ defs
  where
    (defs, ref) = runDeclare (declareSchemaRef (Proxy :: Proxy a)) mempty

noContentEndpoint :: forall cs proxy verb. (AllAccept cs)
  => FilePath
  -> Lens' PathItem (Maybe Operation)
  -> proxy (verb cs ())
  -> Swagger
noContentEndpoint path verb _ = mkEndpointWithSchemaRef Nothing path verb 204 (Proxy :: Proxy (verb cs (Headers '[] ())))

mkEndpointWithSchemaRef :: forall cs hs proxy verb a. (AllAccept cs, AllToResponseHeader hs)
  => Maybe (Referenced Schema)
  -> FilePath
  -> Lens' PathItem (Maybe Operation)
  -> HttpStatusCode
  -> proxy (verb cs (Headers hs a))
  -> Swagger
mkEndpointWithSchemaRef mref path verb code _ = mempty
  & paths.at path ?~
    (mempty & verb ?~ (mempty
      & produces ?~ MimeList (allContentType (Proxy :: Proxy cs))
      & at code ?~ Inline (mempty
            & schema  .~ mref
            & headers .~ toAllResponseHeaders (Proxy :: Proxy hs))))
#endif

-- | Add parameter to every operation in the spec.
addParam :: Param -> Swagger -> Swagger
addParam param = allOperations.parameters %~ (Inline param :)

-- | Add accepted content types to every operation in the spec.
addConsumes :: [MediaType] -> Swagger -> Swagger
addConsumes cs = allOperations.consumes %~ (<> Just (MimeList cs))

-- | Format given text as inline code in Markdown.
markdownCode :: Text -> Text
markdownCode s = "`" <> s <> "`"

addDefaultResponse404 :: ParamName -> Swagger -> Swagger
addDefaultResponse404 pname = setResponseWith (\old _new -> alter404 old) 404 (return response404)
  where
    sname = markdownCode pname
    description404 = sname <> " not found"
    alter404 = description %~ ((sname <> " or ") <>)
    response404 = mempty & description .~ description404

addDefaultResponse400 :: ParamName -> Swagger -> Swagger
addDefaultResponse400 pname = setResponseWith (\old _new -> alter400 old) 400 (return response400)
  where
    sname = markdownCode pname
    description400 = "Invalid " <> sname
    alter400 = description %~ (<> (" or " <> sname))
    response400 = mempty & description .~ description400

#if MIN_VERSION_servant(0,5,0)
-- | Methods, available for Swagger.
class SwaggerMethod method where
  swaggerMethod :: proxy method -> Lens' PathItem (Maybe Operation)

instance SwaggerMethod 'GET     where swaggerMethod _ = get
instance SwaggerMethod 'PUT     where swaggerMethod _ = put
instance SwaggerMethod 'POST    where swaggerMethod _ = post
instance SwaggerMethod 'DELETE  where swaggerMethod _ = delete
instance SwaggerMethod 'OPTIONS where swaggerMethod _ = options
instance SwaggerMethod 'HEAD    where swaggerMethod _ = head_
instance SwaggerMethod 'PATCH   where swaggerMethod _ = patch

instance OVERLAPPABLE_ (ToSchema a, AllAccept cs, KnownNat status, SwaggerMethod method) => HasSwagger (Verb method status cs a) where
  toSwagger _ = toSwagger (Proxy :: Proxy (Verb method status cs (Headers '[] a)))

instance (ToSchema a, AllAccept cs, AllToResponseHeader hs, KnownNat status, SwaggerMethod method)
  => HasSwagger (Verb method status cs (Headers hs a)) where
  toSwagger = mkEndpoint "/"

-- | @'Vault'@ combinator does not change our specification at all.
instance (HasSwagger sub) => HasSwagger (Vault :> sub) where
  toSwagger _ = toSwagger (Proxy :: Proxy sub)

-- | @'IsSecure'@ combinator does not change our specification at all.
instance (HasSwagger sub) => HasSwagger (IsSecure :> sub) where
  toSwagger _ = toSwagger (Proxy :: Proxy sub)

-- | @'RemoteHost'@ combinator does not change our specification at all.
instance (HasSwagger sub) => HasSwagger (RemoteHost :> sub) where
  toSwagger _ = toSwagger (Proxy :: Proxy sub)

-- | @'HttpVersion'@ combinator does not change our specification at all.
instance (HasSwagger sub) => HasSwagger (HttpVersion :> sub) where
  toSwagger _ = toSwagger (Proxy :: Proxy sub)
#else
-- -----------------------------------------------------------------------
-- DELETE
-- -----------------------------------------------------------------------

instance OVERLAPPABLE_ (ToSchema a, AllAccept cs) => HasSwagger (Delete cs a) where
  toSwagger _ = toSwagger (Proxy :: Proxy (Delete cs (Headers '[] a)))

instance (ToSchema a, AllAccept cs, AllToResponseHeader hs) => HasSwagger (Delete cs (Headers hs a)) where
  toSwagger = mkEndpoint "/" delete 200

instance AllAccept cs => HasSwagger (Delete cs ()) where
  toSwagger = noContentEndpoint "/" delete

-- -----------------------------------------------------------------------
-- GET
-- -----------------------------------------------------------------------

instance OVERLAPPABLE_ (ToSchema a, AllAccept cs) => HasSwagger (Get cs a) where
  toSwagger _ = toSwagger (Proxy :: Proxy (Get cs (Headers '[] a)))

instance (ToSchema a, AllAccept cs, AllToResponseHeader hs) => HasSwagger (Get cs (Headers hs a)) where
  toSwagger = mkEndpoint "/" get 200

instance AllAccept cs => HasSwagger (Get cs ()) where
  toSwagger = noContentEndpoint "/" get

-- -----------------------------------------------------------------------
-- PATCH
-- -----------------------------------------------------------------------

instance OVERLAPPABLE_ (ToSchema a, AllAccept cs) => HasSwagger (Patch cs a) where
  toSwagger _ = toSwagger (Proxy :: Proxy (Patch cs (Headers '[] a)))

instance (ToSchema a, AllAccept cs, AllToResponseHeader hs) => HasSwagger (Patch cs (Headers hs a)) where
  toSwagger = mkEndpoint "/" patch 200

instance AllAccept cs => HasSwagger (Patch cs ()) where
  toSwagger = noContentEndpoint "/" patch

-- -----------------------------------------------------------------------
-- PUT
-- -----------------------------------------------------------------------

instance OVERLAPPABLE_ (ToSchema a, AllAccept cs) => HasSwagger (Put cs a) where
  toSwagger _ = toSwagger (Proxy :: Proxy (Put cs (Headers '[] a)))

instance (ToSchema a, AllAccept cs, AllToResponseHeader hs) => HasSwagger (Put cs (Headers hs a)) where
  toSwagger = mkEndpoint "/" put 200

instance AllAccept cs => HasSwagger (Put cs ()) where
  toSwagger = noContentEndpoint "/" put

-- -----------------------------------------------------------------------
-- POST
-- -----------------------------------------------------------------------

instance OVERLAPPABLE_ (ToSchema a, AllAccept cs) => HasSwagger (Post cs a) where
  toSwagger _ = toSwagger (Proxy :: Proxy (Post cs (Headers '[] a)))

instance (ToSchema a, AllAccept cs, AllToResponseHeader hs) => HasSwagger (Post cs (Headers hs a)) where
  toSwagger = mkEndpoint "/" post 201

instance AllAccept cs => HasSwagger (Post cs ()) where
  toSwagger = noContentEndpoint "/" post
#endif

instance (HasSwagger a, HasSwagger b) => HasSwagger (a :<|> b) where
  toSwagger _ = toSwagger (Proxy :: Proxy a) <> toSwagger (Proxy :: Proxy b)

-- | @'WithNamedContext'@ combinator does not change our specification at all.
instance (HasSwagger sub) => HasSwagger (WithNamedContext x c sub) where
  toSwagger _ = toSwagger (Proxy :: Proxy sub)

instance (KnownSymbol sym, HasSwagger sub) => HasSwagger (sym :> sub) where
  toSwagger _ = prependPath piece (toSwagger (Proxy :: Proxy sub))
    where
      piece = symbolVal (Proxy :: Proxy sym)

instance (KnownSymbol sym, ToParamSchema a, HasSwagger sub) => HasSwagger (Capture sym a :> sub) where
  toSwagger _ = toSwagger (Proxy :: Proxy sub)
    & addParam param
    & prependPath capture
    & addDefaultResponse404 tname
    where
      pname = symbolVal (Proxy :: Proxy sym)
      tname = Text.pack pname
      capture = "{" <> pname <> "}"
      param = mempty
        & name .~ tname
        & required ?~ True
        & schema .~ ParamOther (mempty
            & in_ .~ ParamPath
            & paramSchema .~ toParamSchema (Proxy :: Proxy a))

instance (KnownSymbol sym, ToParamSchema a, HasSwagger sub) => HasSwagger (QueryParam sym a :> sub) where
  toSwagger _ = toSwagger (Proxy :: Proxy sub)
    & addParam param
    & addDefaultResponse400 tname
    where
      tname = Text.pack (symbolVal (Proxy :: Proxy sym))
      param = mempty
        & name .~ tname
        & schema .~ ParamOther (mempty
            & in_ .~ ParamQuery
            & paramSchema .~ toParamSchema (Proxy :: Proxy a))

instance (KnownSymbol sym, ToParamSchema a, HasSwagger sub) => HasSwagger (QueryParams sym a :> sub) where
  toSwagger _ = toSwagger (Proxy :: Proxy sub)
    & addParam param
    & addDefaultResponse400 tname
    where
      tname = Text.pack (symbolVal (Proxy :: Proxy sym))
      param = mempty
        & name .~ tname
        & schema .~ ParamOther (mempty
            & in_ .~ ParamQuery
            & paramSchema .~ (mempty
                & type_ .~ SwaggerArray
                & items ?~ SwaggerItemsPrimitive (Just CollectionMulti) (toParamSchema (Proxy :: Proxy a))))

instance (KnownSymbol sym, HasSwagger sub) => HasSwagger (QueryFlag sym :> sub) where
  toSwagger _ = toSwagger (Proxy :: Proxy sub)
    & addParam param
    & addDefaultResponse400 tname
    where
      tname = Text.pack (symbolVal (Proxy :: Proxy sym))
      param = mempty
        & name .~ tname
        & schema .~ ParamOther (mempty
            & in_ .~ ParamQuery
            & allowEmptyValue ?~ True
            & paramSchema .~ (toParamSchema (Proxy :: Proxy Bool)
                & default_ ?~ toJSON False))

instance (KnownSymbol sym, ToParamSchema a, HasSwagger sub) => HasSwagger (Header sym a :> sub) where
  toSwagger _ = toSwagger (Proxy :: Proxy sub)
    & addParam param
    & addDefaultResponse400 tname
    where
      tname = Text.pack (symbolVal (Proxy :: Proxy sym))
      param = mempty
        & name .~ tname
        & schema .~ ParamOther (mempty
            & in_ .~ ParamHeader
            & paramSchema .~ toParamSchema (Proxy :: Proxy a))

instance (ToSchema a, AllAccept cs, HasSwagger sub) => HasSwagger (ReqBody cs a :> sub) where
  toSwagger _ = toSwagger (Proxy :: Proxy sub)
    & addParam param
    & addConsumes (allContentType (Proxy :: Proxy cs))
    & addDefaultResponse400 tname
    & definitions %~ (<> defs)
    where
      tname = "body"
      (defs, ref) = runDeclare (declareSchemaRef (Proxy :: Proxy a)) mempty
      param = mempty
        & name      .~ tname
        & required  ?~ True
        & schema    .~ ParamBody ref

-- =======================================================================
-- Below are the definitions that should be in Servant.API.ContentTypes
-- =======================================================================

class AllAccept cs where
  allContentType :: Proxy cs -> [MediaType]

instance AllAccept '[] where
  allContentType _ = []

instance (Accept c, AllAccept cs) => AllAccept (c ': cs) where
  allContentType _ = contentType (Proxy :: Proxy c) : allContentType (Proxy :: Proxy cs)

class ToResponseHeader h where
  toResponseHeader :: Proxy h -> (HeaderName, Swagger.Header)

instance (KnownSymbol sym, ToParamSchema a) => ToResponseHeader (Header sym a) where
  toResponseHeader _ = (hname, Swagger.Header Nothing hschema)
    where
      hname = Text.pack (symbolVal (Proxy :: Proxy sym))
      hschema = toParamSchema (Proxy :: Proxy a)

class AllToResponseHeader hs where
  toAllResponseHeaders :: Proxy hs -> HashMap HeaderName Swagger.Header

instance AllToResponseHeader '[] where
  toAllResponseHeaders _ = mempty

instance (ToResponseHeader h, AllToResponseHeader hs) => AllToResponseHeader (h ': hs) where
  toAllResponseHeaders _ = HashMap.insert hname header hdrs
    where
      (hname, header) = toResponseHeader (Proxy :: Proxy h)
      hdrs = toAllResponseHeaders (Proxy :: Proxy hs)

instance AllToResponseHeader hs => AllToResponseHeader (HList hs) where
  toAllResponseHeaders _ = toAllResponseHeaders (Proxy :: Proxy hs)
