-- |
-- Module:      Servant.Swagger
-- License:     BSD3
-- Maintainer:  Nickolay Kudasov <nickolay@getshoptv.com>
-- Stability:   experimental
--
-- This module provides means to generate and manipulate
-- Swagger specification for servant APIs.
--
-- Swagger is a project used to describe and document RESTful APIs.
--
-- The Swagger specification defines a set of files required to describe such an API.
-- These files can then be used by the Swagger-UI project to display the API
-- and Swagger-Codegen to generate clients in various languages.
-- Additional utilities can also take advantage of the resulting files, such as testing tools.
--
-- For more information see <http://swagger.io/ Swagger documentation>.
module Servant.Swagger (
  -- * How to use this library
  -- $howto

  -- ** Generate @'Swagger'@
  -- $generate

  -- ** Annotate
  -- $annotate

  -- ** Test
  -- $test

  -- ** Serve
  -- $serve

  -- * @'HasSwagger'@ class
  HasSwagger(..),

  -- * Manipulation
  subOperations,

  -- * Testing
  validateEveryToJSON,
  validateEveryToJSONWithPatternChecker,
) where

import           Servant.Swagger.Internal
import           Servant.Swagger.Test

-- $setup
-- >>> import Control.Applicative
-- >>> import Control.Lens
-- >>> import Data.Aeson
-- >>> import Data.Swagger
-- >>> import Data.Typeable
-- >>> import GHC.Generics
-- >>> import Servant.API
-- >>> import Test.Hspec
-- >>> import Test.QuickCheck
-- >>> import qualified Data.ByteString.Lazy.Char8 as BSL8
-- >>> :set -XDataKinds
-- >>> :set -XDeriveDataTypeable
-- >>> :set -XDeriveGeneric
-- >>> :set -XGeneralizedNewtypeDeriving
-- >>> :set -XOverloadedStrings
-- >>> :set -XTypeOperators
-- >>> data User = User { name :: String, age :: Int } deriving (Show, Generic, Typeable)
-- >>> newtype UserId = UserId Integer deriving (Show, Generic, Typeable, ToJSON)
-- >>> instance ToJSON User
-- >>> instance ToSchema User
-- >>> instance ToSchema UserId
-- >>> instance ToParamSchema UserId
-- >>> type GetUsers = Get '[JSON] [User]
-- >>> type GetUser  = Capture "user_id" UserId :> Get '[JSON] User
-- >>> type PostUser = ReqBody '[JSON] User :> Post '[JSON] UserId
-- >>> type UserAPI  = GetUsers :<|> GetUser :<|> PostUser

-- $howto
--
-- This section explains how to use this library to generate Swagger specification,
-- modify it and run automatic tests for a servant API.
--
-- For the purposes of this section we will use this servant API:
--
-- >>> data User = User { name :: String, age :: Int } deriving (Show, Generic, Typeable)
-- >>> newtype UserId = UserId Integer deriving (Show, Generic, Typeable, ToJSON)
-- >>> instance ToJSON User
-- >>> instance ToSchema User
-- >>> instance ToSchema UserId
-- >>> instance ToParamSchema UserId
-- >>> type GetUsers = Get '[JSON] [User]
-- >>> type GetUser  = Capture "user_id" UserId :> Get '[JSON] User
-- >>> type PostUser = ReqBody '[JSON] User :> Post '[JSON] UserId
-- >>> type UserAPI  = GetUsers :<|> GetUser :<|> PostUser
--
-- Here we define a user API with three endpoints. @GetUsers@ endpoint returns a list of all users.
-- @GetUser@ returns a user given his\/her ID. @PostUser@ creates a new user and returns his\/her ID.

-- $generate
-- In order to generate @'Swagger'@ specification for a servant API, just use @'toSwagger'@:
--
-- >>> BSL8.putStrLn $ encode $ toSwagger (Proxy :: Proxy UserAPI)
-- {"swagger":"2.0","info":{"version":"","title":""},"paths":{"/":{"get":{"produces":["application/json;charset=utf-8"],"responses":{"200":{"schema":{"items":{"$ref":"#/definitions/User"},"type":"array"},"description":""}}},"post":{"consumes":["application/json;charset=utf-8"],"produces":["application/json;charset=utf-8"],"parameters":[{"required":true,"schema":{"$ref":"#/definitions/User"},"in":"body","name":"body"}],"responses":{"400":{"description":"Invalid `body`"},"200":{"schema":{"$ref":"#/definitions/UserId"},"description":""}}}},"/{user_id}":{"get":{"produces":["application/json;charset=utf-8"],"parameters":[{"required":true,"in":"path","name":"user_id","type":"integer"}],"responses":{"404":{"description":"`user_id` not found"},"200":{"schema":{"$ref":"#/definitions/User"},"description":""}}}}},"definitions":{"User":{"required":["name","age"],"properties":{"name":{"type":"string"},"age":{"maximum":9223372036854775807,"minimum":-9223372036854775808,"type":"integer"}},"type":"object"},"UserId":{"type":"integer"}}}
--
-- By default @'toSwagger'@ will generate specification for all API routes, parameters, headers, responses and data schemas.
--
-- For some parameters it will also add 400 and/or 404 responses with a description mentioning parameter name.
--
-- Data schemas come from @'ToParamSchema'@ and @'ToSchema'@ classes.

-- $annotate
-- While initially generated @'Swagger'@ looks good, it lacks some information it can't get from a servant API.
--
-- We can add this information using field lenses from @"Data.Swagger"@:
--
-- >>> :{
-- BSL8.putStrLn $ encode $ toSwagger (Proxy :: Proxy UserAPI)
--   & info.title        .~ "User API"
--   & info.version      .~ "1.0"
--   & info.description  ?~ "This is an API for the Users service"
--   & info.license      ?~ "MIT"
--   & host              ?~ "example.com"
-- :}
-- {"swagger":"2.0","info":{"version":"1.0","title":"User API","license":{"name":"MIT"},"description":"This is an API for the Users service"},"host":"example.com","paths":{"/":{"get":{"produces":["application/json;charset=utf-8"],"responses":{"200":{"schema":{"items":{"$ref":"#/definitions/User"},"type":"array"},"description":""}}},"post":{"consumes":["application/json;charset=utf-8"],"produces":["application/json;charset=utf-8"],"parameters":[{"required":true,"schema":{"$ref":"#/definitions/User"},"in":"body","name":"body"}],"responses":{"400":{"description":"Invalid `body`"},"200":{"schema":{"$ref":"#/definitions/UserId"},"description":""}}}},"/{user_id}":{"get":{"produces":["application/json;charset=utf-8"],"parameters":[{"required":true,"in":"path","name":"user_id","type":"integer"}],"responses":{"404":{"description":"`user_id` not found"},"200":{"schema":{"$ref":"#/definitions/User"},"description":""}}}}},"definitions":{"User":{"required":["name","age"],"properties":{"name":{"type":"string"},"age":{"maximum":9223372036854775807,"minimum":-9223372036854775808,"type":"integer"}},"type":"object"},"UserId":{"type":"integer"}}}
--
-- It is also useful to annotate or modify certain endpoints.
-- @'subOperations'@ provides a convenient way to zoom into a part of an API.
--
-- @'subOperations' sub api@ traverses all operations of the @api@ which are also present in @sub@.
-- Furthermore, @sub@ is required to be an exact sub API of @api. Otherwise it will not typecheck.
--
-- @"Data.Swagger.Operation"@ provides some useful helpers that can be used with @'subOperations'@.
-- One example is applying tags to certain endpoints:
--
-- >>> let getOps  = subOperations (Proxy :: Proxy (GetUsers :<|> GetUser)) (Proxy :: Proxy UserAPI)
-- >>> let postOps = subOperations (Proxy :: Proxy PostUser) (Proxy :: Proxy UserAPI)
-- >>> :{
-- BSL8.putStrLn $ encode $ toSwagger (Proxy :: Proxy UserAPI)
--   & applyTagsFor getOps  ["get"  & description ?~ "GET operations"]
--   & applyTagsFor postOps ["post" & description ?~ "POST operations"]
-- :}
-- {"swagger":"2.0","info":{"version":"","title":""},"paths":{"/":{"get":{"tags":["get"],"produces":["application/json;charset=utf-8"],"responses":{"200":{"schema":{"items":{"$ref":"#/definitions/User"},"type":"array"},"description":""}}},"post":{"tags":["post"],"consumes":["application/json;charset=utf-8"],"produces":["application/json;charset=utf-8"],"parameters":[{"required":true,"schema":{"$ref":"#/definitions/User"},"in":"body","name":"body"}],"responses":{"400":{"description":"Invalid `body`"},"200":{"schema":{"$ref":"#/definitions/UserId"},"description":""}}}},"/{user_id}":{"get":{"tags":["get"],"produces":["application/json;charset=utf-8"],"parameters":[{"required":true,"in":"path","name":"user_id","type":"integer"}],"responses":{"404":{"description":"`user_id` not found"},"200":{"schema":{"$ref":"#/definitions/User"},"description":""}}}}},"definitions":{"User":{"required":["name","age"],"properties":{"name":{"type":"string"},"age":{"maximum":9223372036854775807,"minimum":-9223372036854775808,"type":"integer"}},"type":"object"},"UserId":{"type":"integer"}},"tags":[{"name":"get","description":"GET operations"},{"name":"post","description":"POST operations"}]}
--
-- This applies @\"get\"@ tag to the @GET@ endpoints and @\"post\"@ tag to the @POST@ endpoint of the User API.

-- $test
-- Automatic generation of data schemas uses @'ToSchema'@ instances for the types
-- used in a servant API. But to encode/decode actual data servant uses different classes.
-- For instance in @UserAPI@ @User@ is always encoded/decoded using @'ToJSON'@ and @'FromJSON'@ instances.
--
-- To be sure your Haskell server/client handles data properly you need to check
-- that @'ToJSON'@ instance always generates values that satisfy schema produced
-- by @'ToSchema'@ instance.
--
-- With @'validateEveryToJSON'@ it is possible to test all those instances automatically,
-- without having to write down every type:
--
-- >>> instance Arbitrary User where arbitrary = User <$> arbitrary <*> arbitrary
-- >>> instance Arbitrary UserId where arbitrary = UserId <$> arbitrary
-- >>> hspec $ validateEveryToJSON (Proxy :: Proxy UserAPI)
-- <BLANKLINE>
-- [User]
-- ...
-- User
-- ...
-- UserId
-- ...
-- Finished in ... seconds
-- 3 examples, 0 failures
--
-- Although servant is great, chances are that your API clients don't use Haskell.
-- In many cases @swagger.json@ serves as a specification, not a Haskell type.
--
-- In this cases it is a good idea to store generated and annotated @'Swagger'@ in a @swagger.json@ file
-- under a version control system (such as Git, Subversion, Mercurial, etc.).
--
-- It is also recommended to version API based on changes to the @swagger.json@ rather than changes
-- to the Haskell API.
--
-- See <example/test/TodoSpec.hs TodoSpec.hs> for an example of a complete test suite for a swagger specification.

-- $serve
-- If you're implementing a server for an API, you might also want to serve its @'Swagger'@ specification.
--
-- See <example/src/Todo.hs Todo.hs> for an example of a server.
