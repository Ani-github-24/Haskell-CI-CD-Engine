{-# LANGUAGE NoRebindableSyntax #-}
{-# OPTIONS_GHC -fno-warn-missing-import-lists #-}
{-# OPTIONS_GHC -w #-}
module PackageInfo_ci_cd_engine (
    name,
    version,
    synopsis,
    copyright,
    homepage,
  ) where

import Data.Version (Version(..))
import Prelude

name :: String
name = "ci_cd_engine"
version :: Version
version = Version [0,1,0,0] []

synopsis :: String
synopsis = "Research-grade distributed CI/CD engine with Jenkins-style dashboard"
copyright :: String
copyright = ""
homepage :: String
homepage = ""
