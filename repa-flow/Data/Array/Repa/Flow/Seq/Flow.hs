

-- | Flows provide an incremental version of array fusion that allows the
--   the computation to be suspended and resumed at a later time.
module Data.Array.Repa.Flow.Seq.Flow
        ( module Data.Array.Repa.Flow.Base
        , Flow(..)
        , Step1(..)
        , Step8(..)
        , flow
        , unflow
        , take
        , drain
        , slurp)
where
import Data.Array.Repa.Bulk.Elt
import Data.Array.Repa.Flow.Base
import Data.Array.Repa.Flow.Seq.Base
import qualified Data.Array.Repa.Flow.Seq.Report        as R
import qualified Data.Vector.Unboxed                    as U
import System.IO.Unsafe
import Prelude                                          hiding (take)
import GHC.Exts


-- | Flows provide an incremental version of array fusion that allows the
--   the computation to be suspended and resumed at a later time.
-- 
--   Using the `flowGet8` interface, eight elements of a flow can be 
--   computed for each loop iteration, producing efficient object code.
data Flow r a
        = forall state. Flow
        { 
          -- | Start the flow. 
          --   This returns a state value that needs to be passed to
          --   the get functions.
          flowStart     :: IO state

          -- | How many elements are available in this flow.
        , flowSize      :: state -> IO Size

          -- | Report the current state of this flow.
        , flowReport    :: state -> IO R.Report

          -- | Takes a continuation and calls it with
          --   a `Step1` containing some data.
        , flowGet1      :: state -> (Step1 a -> IO ()) -> IO ()

          -- | Takes a continuation and calls it with 
          --  a `Step8` containing some data.
        , flowGet8      :: state -> (Step8 a -> IO ()) -> IO ()
        }


data Step1 a
        -- | An element and a flag saying whether a full 8 elements are
        --   likely to be available next pull.
        --
        ---  We don't want to *force* the consumer to pull the full 8
        --   if it doesn't want to, otherwise functions like folds would
        --   become too complicated.
        = Yield1 a Bool

        -- | The flow is finished, no more elements will ever be available.
        | Done


data Step8 a
        -- | Eight successive elements of the flow.
        = Yield8 a a a a a a a a

        -- | Indicates that the flow cannot yield a full 8 elements right now.
        --   You should use `flowGet1` to get the next element and try
        --  `flowGet8` again later.
        | Pull1


-------------------------------------------------------------------------------
-- | Create a delayed flow.
flow    :: Elt a 
        => (Int# -> a)  -- ^ Function to get the element at the given index.
        -> Int#         -- ^ Total number of elements.
        -> Flow mode a

flow !load !len
 = Flow start size report get1 get8
 where  
        here    = "seq.flow"

        start
         = do   refIx   <- inew 1
                iwrite here refIx 0# 0#
                return refIx
        {-# INLINE start #-}


        size refIx
         = do   !(I# ix)        <- iread here refIx 0#
                return  $ Exact (len -# ix)
        {-# INLINE size #-}


        report refIx
         = do   !ix             <- iread here refIx 0#
                return  $ R.Flow (I# len) ix
        {-# NOINLINE report #-}


        get1 refIx push1
         = do   !(I# ix)        <- iread here refIx 0#
                let !remain     =  len -# ix
                if remain ># 0#
                 then do
                        iwrite here refIx 0# (ix +# 1#)
                        let !x  = load ix

                        -- Touch because we want to be sure its unboxed as
                        -- soon as we read it. It we don't touch it, and
                        -- the continuation uses the value in multiple
                        -- case branches then it can be reboxed and then
                        -- unboxed again multiple times.
                        touch x

                        push1 $ Yield1 x (remain >=# 9#)

                 else   push1 Done
        {-# INLINE get1 #-}


        get8 refIx push8
         = do   !(I# ix)        <- iread here refIx 0#
                let !remain     = len -# ix
                if remain >=# 8#
                 then do
                        iwrite here refIx 0# (ix +# 8#)

                        -- TODO: not sure whether we should force these here
                        let here' = return

                        !x0     <- here' $ load (ix +# 0#)
                        !x1     <- here' $ load (ix +# 1#)
                        !x2     <- here' $ load (ix +# 2#)
                        !x3     <- here' $ load (ix +# 3#)
                        !x4     <- here' $ load (ix +# 4#)
                        !x5     <- here' $ load (ix +# 5#)
                        !x6     <- here' $ load (ix +# 6#)
                        !x7     <- here' $ load (ix +# 7#)

                        push8 $ Yield8 x0 x1 x2 x3 x4 x5 x6 x7

                 else do
                        push8 Pull1
        {-# INLINE get8 #-}

{-# INLINE [1] flow #-}


-------------------------------------------------------------------------------
-- | Fully evaluate a delayed flow, producing an unboxed vector.
--   TODO: make this generic in the returned vector type.
unflow :: (Elt a, U.Unbox a) 
        => Flow FD a -> U.Vector a
unflow ff 
 = unsafePerformIO 
 $ do   let here = "seq.unflow"

        let new ix        = unew (I# ix)
        let write mvec ix = uwrite here mvec (I# ix)
        (mvec, len)       <- drain new write ff

        !vec              <- U.unsafeFreeze mvec
        return  $ uslice 0 len vec

{-# INLINE [1] unflow #-}


-------------------------------------------------------------------------------
-- | Take at most the given number of elements from the front of a flow,
--   returning those elements and the rest of the flow.
--   
--   Calling 'take' allocates buffers and other state information, 
--   and this state will be reused when the remaining elements of
--   the flow are evaluated.
--
--   TODO: make this generic in the returned vector type.
--
take    :: (Elt a, U.Unbox a) 
        => Int# -> Flow mode a -> IO (U.Vector a, Flow FS a)

take limit (Flow start size report get1 get8)
 = do   let here = "seq.take"

        -- Start the flow, if it isn't already.
        state    <- start

        -- Allocate the buffer for the result.
        !mvec    <- unew (I# limit)

        -- Slurp elemenst into the result buffer.
        let write ix x = uwrite here mvec (I# ix) x
        !len'    <- slurp 0# (Just (I# limit)) write
                        (get1 state) (get8 state)

        !vec     <- ufreeze mvec
        let !vec' = uslice 0 len' vec        

        return  ( vec'
                , Flow (return state) size report get1 get8)
{-# INLINE [1] take #-}


-------------------------------------------------------------------------------
-- | Fully evaluate a possibly stateful flow,
--   pulling all the remaining elements.
drain   :: Elt a 
        => (Int#  -> IO (vec a))          -- ^ Allocate a new vector.
        -> (vec a -> Int# -> a -> IO ())  -- ^ Write into the vector.
        -> Flow mode a          -- ^ Flow to evaluate.
        -> IO (vec a, Int)      -- ^ Result vector, and number of elements written.

drain new write !ff
 = case ff of
    Flow fStart fSize _fReport fGet1 fGet8
     -> do !state   <- fStart
           !size    <- fSize   state 


           -- In the sequential case we can use the same code to unflow
           -- both Exact and Max, and just slice down the vector to the
           -- final size.
           case size of
            Exact len       
             -> do !mvec <- new len

                   let write' = write mvec
                   len'  <- slurp 0# Nothing write' (fGet1 state) (fGet8 state)

                   return (mvec, len')

            Max   len   
             -> do !mvec <- new len

                   let write' = write mvec
                   len'  <- slurp 0# Nothing write' (fGet1 state) (fGet8 state)

                   return (mvec, len')

{-# INLINE [1] drain #-}


-------------------------------------------------------------------------------
-- | Slurp out all the available elements from a flow, passing them to the
--   provided consumption function. If the flow stalls then only the currently
--   available elements are produced.
slurp   :: Elt a
        => Int#                           -- ^ Starting index in result.
        -> Maybe Int                      -- ^ Stopping index.
        -> (Int# -> a -> IO ())           -- ^ Write an element into the result.
        -> ((Step1 a  -> IO ()) -> IO ()) -- ^ Get one element from the flow.
        -> ((Step8 a  -> IO ()) -> IO ()) -- ^ Get eight elements from the flow.
        -> IO Int                         -- ^ Total number of elements written.

slurp start stop !write get1 get8
 = do   let here = "seq.slurp"

        refCount <- inew 1
        iwrite here refCount 0# (-1#)

        let
         {-# INLINE slurpSome #-}
         slurpSome ix
          = do  slurp8 ix
                I# ix'     <- iread here refCount 0# 

                slurp1 ix'
                I# ix''    <- iread here refCount 0#

                case stop of
                 Just (I# limit)
                  -> if ix'' ==# ix || ix'' >=# limit
                        then return (I# ix'')
                        else slurpSome ix''

                 Nothing
                  -> if ix'' ==# ix
                        then return (I# ix'')
                        else slurpSome ix''

         {-# INLINE slurp1 #-}
         slurp1 ix 
          | Just (I# limit) <- stop
          , ix >=# limit
          =     iwrite here refCount 0# ix

          |  otherwise
          =  get1 $ \r
          -> case r of
                Yield1 x switch
                 -> do  
                        write ix x

                        -- Touch 'x' here because we don't want the code
                        -- that computes it to be floated into the switch
                        -- and then copied.
                        touch x

                        if switch 
                         then iwrite here refCount 0# (ix +# 1#)
                         else slurp1 (ix +# 1#)

                Done  -> iwrite here refCount 0# ix
                        
         {-# INLINE slurp8 #-}
         slurp8 ix
          | Just (I# limit)     <- stop
          , ix +# 8# ># limit
          =     iwrite here refCount 0# ix

          | otherwise
          =  get8 $ \r
          -> case r of
                Yield8 x0 x1 x2 x3 x4 x5 x6 x7
                 -> do  write (ix +# 0#) x0
                        write (ix +# 1#) x1
                        write (ix +# 2#) x2
                        write (ix +# 3#) x3
                        write (ix +# 4#) x4
                        write (ix +# 5#) x5
                        write (ix +# 6#) x6
                        write (ix +# 7#) x7
                        slurp8 (ix +# 8#)

                Pull1   
                 ->     iwrite here refCount 0# ix

        slurpSome start
{-# INLINE [0] slurp #-}
