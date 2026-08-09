/*
* Cedarx framework.
* Copyright (c) 2008-2015 Allwinner Technology Co. Ltd.
* Copyright (c) 2014 BZ Chen <bzchen@allwinnertech.com>
*
* This file is part of Cedarx.
*
* Cedarx is free software; you can redistribute it and/or
* modify it under the terms of the GNU Lesser General Public
* License as published by the Free Software Foundation; either
* version 2.1 of the License, or (at your option) any later version.
*
* This program is distributed "as is" WITHOUT ANY WARRANTY of any
* kind, whether express or implied; without even the implied warranty
* of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
* GNU Lesser General Public License for more details.
*/
#include <unistd.h>
#include <stdlib.h>
#include <memory.h>
#include <malloc.h>
#include "videoengine.h"
#include "log.h"
#include "veregister.h"
//#include "CdxConfig.h"
#include "vdecoder_config.h"

#include <CdxList.h>
#include <CdxLog.h>

unsigned int gVeVersion;
extern const char* strCodecFormat[];

static void EnableVeSpecificDecoder(VideoEngine* p);
static void DisableVeSpecificDecoder(VideoEngine* p);

struct VDecoderNodeS
{
    CdxListNodeT node;
    VDecoderCreator *creator;
    char desc[64]; /* specific by mime type */
    enum EVIDEOCODECFORMAT format;
    
};

struct VDecoderListS
{
    CdxListT list;
    int size;
    pthread_mutex_t mutex;
};

static struct VDecoderListS gVDecoderList = {{NULL, NULL}, 0, PTHREAD_MUTEX_INITIALIZER};

int VDecoderRegister(enum EVIDEOCODECFORMAT format, char *desc, VDecoderCreator *creator)
{
    struct VDecoderNodeS *newVDNode = NULL, *posVDNode = NULL;
    
    CDX_ASSERT(desc);
    if (strlen(desc) > 63)
    {
        loge("type name '%s' too long", desc);
        return -1;
    }
    
    if (gVDecoderList.size == 0)
    {
        CdxListInit(&gVDecoderList.list);
        pthread_mutex_init(&gVDecoderList.mutex, NULL);
    }

    pthread_mutex_lock(&gVDecoderList.mutex);

    /* check if conflict */
    CdxListForEachEntry(posVDNode, &gVDecoderList.list, node)
    {
        if (posVDNode->format == format)
        {
            loge("Add '%x:%s' fail! '%x:%s' already register!", format, desc, format, posVDNode->desc);
            pthread_mutex_unlock(&gVDecoderList.mutex);
            return -1;
        }
    }

    newVDNode = malloc(sizeof(*newVDNode));
    newVDNode->creator = creator;
    strncpy(newVDNode->desc, desc, 63);
    newVDNode->format = format;

    CdxListAdd(&newVDNode->node, &gVDecoderList.list);
    gVDecoderList.size++;
    
    pthread_mutex_unlock(&gVDecoderList.mutex);
    logi("register codec: '%x:%s' success.", format, desc);
    return 0;
}

static DecoderInterface* CreateSpecificDecoder(VideoEngine* p)
{
    DecoderInterface* pInterface = NULL;
    struct VDecoderNodeS *posVDNode = NULL;

    CdxListForEachEntry(posVDNode, &gVDecoderList.list, node)
    {
        if (posVDNode->format == p->videoStreamInfo.eCodecFormat)
        {
            logi("Create decoder '%x:%s'", posVDNode->format, posVDNode->desc);
            pInterface = posVDNode->creator(p);
            return pInterface;
        }
    }

    loge("format '%x' support!", p->videoStreamInfo.eCodecFormat);
    return NULL;
}

void SetVeTopLevelRegisters(VideoEngine* p)
{
    vetop_reglist_t* vetop_reg_list;

    vetop_reg_list = (vetop_reglist_t*)ve_get_reglist(REG_GROUP_VETOP);

#if CONFIG_USE_TIMEOUT_CONTROL

    //* set maximum cycle count for decoding one frame.
    vetop_reg_list->_0c_overtime.overtime_value = CONFIG_TIMEOUT_VALUE;

#else   //* #if CONFIG_USE_TIMEOUT_CONTROL

    //* disable timeout interrupt.
    vetop_reg_list->_1c_status.timeout_enable = 0;

#endif   //* #if CONFIG_USE_TIMEOUT_CONTROL

	VeDecoderWidthMode(p->videoStreamInfo.nWidth);
	EnableVeSpecificDecoder(p);
}


void ResetVeInternal(VideoEngine* p)
{
    volatile unsigned int dwVal;
    int i;
    vetop_reglist_t* vetop_reg_list;
    
    DisableVeSpecificDecoder(p);
	VeResetDecoder();
	EnableVeSpecificDecoder(p);
    SetVeTopLevelRegisters(p);
}


static void EnableVeSpecificDecoder(VideoEngine* p)
{
    int codecFormat = p->videoStreamInfo.eCodecFormat;
    enum VeRegionE region = VE_REGION_INVALID;
    
    switch (codecFormat)
    {
        case VIDEO_CODEC_FORMAT_H264:
        case VIDEO_CODEC_FORMAT_VP8:
            region = VE_REGION_1;
            break;
        case VIDEO_CODEC_FORMAT_MPEG1:
        case VIDEO_CODEC_FORMAT_MPEG2:
        case VIDEO_CODEC_FORMAT_XVID:
        case VIDEO_CODEC_FORMAT_H263:
        case VIDEO_CODEC_FORMAT_MJPEG:
            region = VE_REGION_0;
            break;
        case VIDEO_CODEC_FORMAT_WMV3:
            region = VE_REGION_2;
            break;
            
        default:
            break;
    }
    
	VeEnableDecoder(region);
	
    return;
}

static void DisableVeSpecificDecoder(VideoEngine* p)
{
	VeDisableDecoder();
    return;
}

VideoEngine* VideoEngineCreate(VConfig* pVConfig, VideoStreamInfo* pVideoInfo)
{
    int          ret;
    VideoEngine* pEngine;
    
    pEngine = (VideoEngine*)malloc(sizeof(VideoEngine));
    if(pEngine == NULL)
    {
        loge("memory alloc fail, VideoEngineCreate() return fail.");
        return pEngine;
    }
    memset(pEngine, 0, sizeof(VideoEngine));
    memcpy(&pEngine->vconfig, pVConfig, sizeof(VConfig));
    memcpy(&pEngine->videoStreamInfo, pVideoInfo, sizeof(VideoStreamInfo));
    
    if(pVideoInfo->nCodecSpecificDataLen > 0 && pVideoInfo->pCodecSpecificData != NULL)
    {
        pEngine->videoStreamInfo.pCodecSpecificData = (char*)malloc(pVideoInfo->nCodecSpecificDataLen);
        if(pEngine->videoStreamInfo.pCodecSpecificData == NULL)
        {
            loge("memory alloc fail, allocate %d bytes, VideoEngineCreate() return fail.",
                    pVideoInfo->nCodecSpecificDataLen);
            free(pEngine);
            return NULL;
        }
        memcpy(pEngine->videoStreamInfo.pCodecSpecificData, 
               pVideoInfo->pCodecSpecificData,
               pVideoInfo->nCodecSpecificDataLen);
    }
    

    gVeVersion = VeGetIcVersion();

    pEngine->pDecoderInterface = CreateSpecificDecoder(pEngine);
    if(pEngine->pDecoderInterface == NULL)
    {
        loge("unsupported format %s", strCodecFormat[pVideoInfo->eCodecFormat-VIDEO_CODEC_FORMAT_MIN]);
        if(pEngine->videoStreamInfo.pCodecSpecificData != NULL &&
            pEngine->videoStreamInfo.nCodecSpecificDataLen > 0)
            free(pEngine->videoStreamInfo.pCodecSpecificData);
        free(pEngine);
        return NULL;
    }
    
    ResetVeInternal(pEngine);
    SetVeTopLevelRegisters(pEngine);
    pEngine->vconfig.eOutputPixelFormat = PIXEL_FORMAT_YUV_MB32_420;
    //* call specific function to open decoder.
    EnableVeSpecificDecoder(pEngine);
    ret = pEngine->pDecoderInterface->Init(pEngine->pDecoderInterface,
                                           &pEngine->vconfig,
                                           &pEngine->videoStreamInfo);
    DisableVeSpecificDecoder(pEngine);
    
    if(ret != VDECODE_RESULT_OK)
    {
        loge("initial specific decoder fail.");
        
        if(pEngine->videoStreamInfo.pCodecSpecificData != NULL &&
            pEngine->videoStreamInfo.nCodecSpecificDataLen > 0)
            free(pEngine->videoStreamInfo.pCodecSpecificData);
        
        free(pEngine);
        return NULL;
    }
    
    return pEngine;
}


void VideoEngineDestroy(VideoEngine* pVideoEngine)
{
    //* close specific decoder.
    EnableVeSpecificDecoder(pVideoEngine);
    pVideoEngine->pDecoderInterface->Destroy(pVideoEngine->pDecoderInterface);
    DisableVeSpecificDecoder(pVideoEngine);
    
    //* free codec specific data.
    if(pVideoEngine->videoStreamInfo.pCodecSpecificData != NULL &&
        pVideoEngine->videoStreamInfo.nCodecSpecificDataLen > 0)
        free(pVideoEngine->videoStreamInfo.pCodecSpecificData);
    free(pVideoEngine);
    
    return;
}


void VideoEngineReset(VideoEngine* pVideoEngine)
{
    EnableVeSpecificDecoder(pVideoEngine);
    pVideoEngine->pDecoderInterface->Reset(pVideoEngine->pDecoderInterface);
    DisableVeSpecificDecoder(pVideoEngine);
    return;
}


int VideoEngineSetSbm(VideoEngine* pVideoEngine, Sbm* pSbm, int nIndex)
{
    int ret;
    EnableVeSpecificDecoder(pVideoEngine);
    ret = pVideoEngine->pDecoderInterface->SetSbm(pVideoEngine->pDecoderInterface,
                                                  pSbm,
                                                  nIndex);
    DisableVeSpecificDecoder(pVideoEngine);
    return ret;
}

int VideoEngineGetFbmNum(VideoEngine* pVideoEngine)
{
    int ret;
    ret = pVideoEngine->pDecoderInterface->GetFbmNum(pVideoEngine->pDecoderInterface);
    return ret;
}

Fbm* VideoEngineGetFbm(VideoEngine* pVideoEngine, int nIndex)
{
    Fbm* pFbm;
    pFbm = pVideoEngine->pDecoderInterface->GetFbm(pVideoEngine->pDecoderInterface, nIndex);
    return pFbm;
}

int VideoEngineDecode(VideoEngine* pVideoEngine,
                      int          bEndOfStream,
                      int          bDecodeKeyFrameOnly,
                      int          bDropBFrameIfDelay,
                      int64_t      nCurrentTimeUs)
{
    int ret;
    EnableVeSpecificDecoder(pVideoEngine);
    ret = pVideoEngine->pDecoderInterface->Decode(pVideoEngine->pDecoderInterface,
                                                  bEndOfStream,
                                                  bDecodeKeyFrameOnly,
                                                  bDropBFrameIfDelay,
                                                  nCurrentTimeUs);
    DisableVeSpecificDecoder(pVideoEngine);
    return ret;
}

int GetBufferSize(int ePixelFormat, int nWidth, int nHeight, int*nYBufferSize, int *nCBufferSize, int* nYLineStride, int* nCLineStride, int nAlignValue)
{
    int   nHeight16Align;
    int   nHeight32Align;
    int   nHeight64Align;
    int   nLineStride;
    int   nMemSizeY;
    int   nMemSizeC;

    nHeight16Align = (nHeight+15) & ~15;
    nHeight32Align = (nHeight+31) & ~31;
    nHeight64Align = (nHeight+63) & ~63;


    switch(ePixelFormat)
    {

        case PIXEL_FORMAT_YUV_MB32_420:
        case PIXEL_FORMAT_YUV_MB32_422:
        case PIXEL_FORMAT_YUV_MB32_444:
            //* for decoder,
            //* height of Y component is required to be 32 aligned.
            //* height of UV component are both required to be 32 aligned.
            //* nLineStride should be 32 aligned.
        	nLineStride = (nWidth+63) &~ 63;
            nMemSizeY = nLineStride*nHeight32Align;

            if(ePixelFormat == PIXEL_FORMAT_YUV_MB32_420)
                nMemSizeC = nLineStride*nHeight64Align/4;
            else if(ePixelFormat == PIXEL_FORMAT_YUV_MB32_422)
                nMemSizeC = nLineStride*nHeight64Align/2;
            else
                nMemSizeC = nLineStride*nHeight64Align;
            break;

        default:
            loge("pixel format incorrect, ePixelFormat=%d", ePixelFormat);
            return -1;
    }
    if(nYBufferSize != NULL)
    {
    	*nYBufferSize = nMemSizeY;
    }
    if(nCBufferSize != NULL)
    {
    	*nCBufferSize = nMemSizeC;
    }
    if(nYLineStride != NULL)
    {
    	*nYLineStride = nLineStride;
    }
    if(nCLineStride != NULL)
    {
    	*nCLineStride = nLineStride>>1;
    }
    return 0;
}
