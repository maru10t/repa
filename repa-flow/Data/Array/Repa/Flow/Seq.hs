
-- | Sequential flows provide an incremental version of array fusion that
--   allows the computation to be suspended and resumed at a later time.
module Data.Array.Repa.Flow.Seq
        ( FD, FS
        , Flow (..)
        , Step1(..)
        , Step8(..)
        , Touch
        
        -- * Conversion
        , flow
        , unflow
        , take
        , drain

        -- * Construction
        , generate
        , replicate
        , replicatesUnboxed
        , replicatesDirect
        , enumFromN
        , appends

        -- * Map
        , map
        , zip,          zipLeft
        , zipWith,      zipLeftWith

        -- * Projection
        , gather

        -- * Pack
        , pack
        , packByTag
        , filter

        -- * Combine
        , combine2
        , combines2

        -- * Reduction
        , foldl
        , folds
        , sums)

where
import Data.Array.Repa.Flow.Seq.Base
import Data.Array.Repa.Flow.Seq.Generate
import Data.Array.Repa.Flow.Seq.Append
import Data.Array.Repa.Flow.Seq.Map
import Data.Array.Repa.Flow.Seq.Pack
import Data.Array.Repa.Flow.Seq.Combine
import Data.Array.Repa.Flow.Seq.Project
import Data.Array.Repa.Flow.Seq.Fold
import Prelude  hiding (map, zip, zipWith, foldl, filter, replicate, take)
