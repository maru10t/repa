-- | Canny edge detector

{-# LANGUAGE PackageImports, BangPatterns #-}
{-# OPTIONS -Wall -fno-warn-missing-signatures -fno-warn-incomplete-patterns #-}

import Data.List
import Data.Word
import Control.Monad
import System.Environment
import Data.Array.Repa as Repa
import Data.Array.Repa.IO.BMP
import qualified Data.Array.Repa.Shape	as S
import Prelude				hiding (compare)

-- Constants ------------------------------------------------------------------
orientUndef   = 0	:: Double
orientHoriz   = 1	:: Double
orientVert    = 2	:: Double
orientPosDiag = 3	:: Double
orientNegDiag = 4	:: Double

edge False = 0 		:: Double
edge True  = 200 	:: Double


-- Main routine ---------------------------------------------------------------
main 
 = do	args	<- getArgs
	case args of
	 [fileIn, fileOut]	-> run fileIn fileOut
	 _			-> usage
	

run fileIn fileOut
 = do	inputImage 	<- liftM (force . either (error . show) id) 
			$ readImageFromBMP fileIn
			
	writeImageToBMP fileOut 
		$ floatToRgb 
		$ canny inputImage

usage
 = putStr $ unlines
	[ "repa-edgedetect <fileIn.bmp> <fileOut.bmp>" ]


-- Edge detection -------------------------------------------------------------
canny 	:: Repa.Array DIM3 Word8 
	-> Repa.Array DIM2 Double

{-# NOINLINE canny #-}
canny input@Manifest{}
 = force output
    where
      output 	= nonMaximumSupression (force mag) (force orient)
      blured 	= blur $ toGrayScale input
      mag 	= gradientIntensityCompute dX dY
      orient 	= gradientOrientationCompute dX dY
      dX 	= gradientXCompute blured
      dY 	= gradientYCompute blured


-- | Image convolution.
imageConvolveKernel
	:: Repa.Array DIM2 Double
	-> Repa.Array DIM2 Double
	-> Repa.Array DIM2 Double 

{-# NOINLINE imageConvolveKernel #-}
imageConvolveKernel kernel@Manifest{} input@Manifest{}
 = kernel `deepSeqArray` input `deepSeqArray`
   force $ traverse input usableRegion update
 where
      _ :. height  :. width 	= extent input
      _ :. kHeight :. kWidth 	= extent kernel 

      !kHeight2	= div kHeight 2
      !kWidth2	= div kWidth  2

      !kExtent	= extent kernel
      !kSize	= S.size kExtent

      usableRegion (sh :. _ :. _)
	= sh :. height - (kHeight - 1) :. width - (kWidth - 1)

      update _ (_ :. i :. j)
        = let	!ikHeight'	= i - kHeight2
		!jkWidth'	= j - kWidth2

	        integrate :: Int -> Double -> Double
		integrate !count !acc
		 | count == kSize		= acc
		 | otherwise
		 = let	!ix@(sh :. x :. y)	= S.fromIndex kExtent count
			!ix'			= sh :. x + ikHeight' :. y + jkWidth'
			!here			= kernel !: ix * input !: ix'
		   in	integrate (count + 1) (acc + here)

	  in	integrate 0 0


-- | Maximum suppression	
nonMaximumSupression 
	:: Repa.Array DIM2 Double
	-> Repa.Array DIM2 Double
	-> Repa.Array DIM2 Double

{-# INLINE nonMaximumSupression #-}
nonMaximumSupression dMag@Manifest{} dOrient@Manifest{}
    = traverse2 dMag dOrient const compare
    where
      _ :. height :. width = extent dMag

      isBoundary i j 
        | i == 0 || j == 0     = True
        | i == width - 1       = True
        | j == height - 1      = True
        | otherwise            = False

      compare get1 get2 d@(sh :. i :. j)
        | isBoundary i j      = edge False 
        | o == orientHoriz    = isMaximum (get1 (sh :. i - 1 :. j))     (get1 (sh :. i + 1 :. j)) 
        | o == orientVert     = isMaximum (get1 (sh :. i     :. j - 1)) (get1 (sh :. i     :. j + 1)) 
        | o == orientPosDiag  = isMaximum (get1 (sh :. i - 1 :. j - 1)) (get1 (sh :. i + 1 :. j + 1)) 
        | o == orientNegDiag  = isMaximum (get1 (sh :. i - 1 :. j + 1)) (get1 (sh :. i + 1 :. j - 1)) 
        | otherwise           = edge False  
      
        where
          o = get2 d  
          intensity = get1 (Z :. i :. j)
          isMaximum intensity1 intensity2
            | intensity < intensity1 = edge False
            | intensity < intensity2 = edge False
            | otherwise              = edge True


-- | XY Gradient calculation
gradientXCompute :: Repa.Array DIM2 Double -> Repa.Array DIM2 Double
{-# NOINLINE gradientXCompute #-}
gradientXCompute input@Manifest{}
 = imageConvolveKernel kernel input
 where kernel 
	= force $ Repa.fromList 
		(Z :. 3 :. 3)	[ -1, 0, 1, 
				  -2, 0, 2,
				  -1, 0, 1 ]


gradientYCompute :: Repa.Array DIM2 Double -> Repa.Array DIM2 Double
{-# NOINLINE gradientYCompute #-}
gradientYCompute input@Manifest{}
 = imageConvolveKernel kernel input
 where kernel
	= force $ Repa.fromList
		(Z :. 3 :. 3)	[ 1,  2,  1, 
		  		  0,  0,  0, 	
				 -1, -2, -1 ]


gradientIntensityCompute :: Repa.Array DIM2 Double -> Repa.Array DIM2 Double -> Repa.Array DIM2 Double
{-# INLINE gradientIntensityCompute #-}
gradientIntensityCompute dX@Manifest{} dY@Manifest{}
    = Repa.zipWith (\x y -> sqrt(x*x + y*y)) dX dY


gradientOrientationCompute :: Repa.Array DIM2 Double -> Repa.Array DIM2 Double -> Repa.Array DIM2 Double
{-# INLINE gradientOrientationCompute #-}
gradientOrientationCompute dX@Manifest{} dY@Manifest{}
    = Repa.force $ Repa.zipWith orientation dX dY
      where
        orientation x y 
          | (x > -40 && x < 40) && (y > -40 && y < 40)              = orientUndef
          | atan2 y x >= (-7 * pi / 8) && atan2 y x < (-5 * pi / 8) = orientPosDiag
          | atan2 y x >= (-5 * pi / 8) && atan2 y x < (-3 * pi / 8) = orientVert
          | atan2 y x >= (-3 * pi / 8) && atan2 y x < (-1 * pi / 8) = orientNegDiag
          | atan2 y x >= (-1 * pi / 8) && atan2 y x < ( 1 * pi / 8) = orientHoriz
          | atan2 y x >= ( 1 * pi / 8) && atan2 y x < ( 3 * pi / 8) = orientPosDiag
          | atan2 y x >= ( 3 * pi / 8) && atan2 y x < ( 5 * pi / 8) = orientVert
          | atan2 y x >= ( 5 * pi / 8) && atan2 y x < ( 7 * pi / 8) = orientNegDiag
          | otherwise = orientHoriz
 

-- | Blurring
{-# NOINLINE blur #-}
blur :: Repa.Array DIM2 Double -> Repa.Array DIM2 Double
blur input@Manifest{}
 = imageConvolveKernel kernel input
 where kernel 	= force 
		$ Repa.fromList (Z :. 5 :. 5) 
		$ Data.List.map (\x -> x / 159) 
			 [2.0,  4.0,  5.0,  4.0, 2.0,
                          4.0,  9.0, 12.0,  9.0, 4.0,
                          5.0, 12.0, 15.0, 12.0, 5.0,
                          4.0,  9.0, 12.0,  9.0, 4.0,
                          2.0,  4.0,  5.0,  4.0, 2.0]


-- | RGB to greyscale conversion.
rgbToLuminance :: Word8 -> Word8 -> Word8 -> Double
{-# INLINE rgbToLuminance #-}
rgbToLuminance r g b 
	= fromIntegral r * 0.3
	+ fromIntegral g * 0.59
	+ fromIntegral b * 0.11

rgbToFloat
        :: Repa.Array DIM3 Word8
        -> Repa.Array DIM2 Double
        
rgbToFloat arrBound@Manifest{}
 = force $ traverse arrBound
        (\(sh :. height :. width :. _)   
                -> sh :. height :. width)

        (\get (sh :. y :. x)
                -> rgbToLuminance
                        (get (sh :. y :. x :. 0))
                        (get (sh :. y :. x :. 1))
                        (get (sh :. y :. x :. 2)))


toGrayScale rgbFrame
     = rgbToFloat rgbFrame

floatToRgb :: Repa.Array DIM2 Double -> Repa.Array DIM3 Word8
floatToRgb arrDoubles@Manifest{}
 = force $ traverse arrDoubles
        (\(sh :. height :. width)
                -> sh :. height :. width :. 4)
                
        (\get (sh :. y :. x :. c)
                -> let !i = get (sh :. y :. x)
                   in   case c of
                          0     -> truncate i
                          1     -> truncate i
                          2     -> truncate i
                          3     -> 0)

