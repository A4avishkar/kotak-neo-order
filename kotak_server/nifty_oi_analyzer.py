#!/usr/bin/env python3
"""
NIFTY / SENSEX Option OI & Expensiveness Analyzer (WebSocket ONLY - Self-Contained)

Uses:
- Expiry data from Redis (keys: kotak:expiry:nifty, kotak:expiry:sensex)
- Embedded WebSocket connections for live data (no external helper files required)
- Stacks live metrics (Spot, OI, PCR, Expensiveness) back into Redis for other apps
- Credentials from b.txt (Kotak Neo)

Features (per index & current expiry):
- Total OI of all Calls vs all Puts (calculated every 60s by default)
- Near-ATM OI (4 ITM + ATM + 4 OTM on each side)
- CE vs PE expensiveness detection around ATM using your midpoint rules (checked every 3s)
- OI carry-forward: if OI not received for a strike, uses last updated value

Prerequisites:
1. Ensure b.txt credentials file exists (Kotak Neo)
2. Ensure Redis is running and populated with expiry data (via process_expiry_data.py)
3. Install dependencies: pip install redis pandas pyotp websocket-client

CLI examples (run during market hours):
  # Continuous mode with Redis storage & auto-reconnect (recommended)
  python nifty_oi_analyzer.py --index NIFTY --continuous --redis
  
  # Specify custom Redis host/port
  python nifty_oi_analyzer.py --index NIFTY --continuous --redis --redis-host 127.0.0.1 --redis-port 6379
"""

import argparse
import json
import math
import os
import re
import sys
import ssl
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional, Tuple

import pandas as pd
import pyotp
import requests
import urllib3
import websocket

# Optional API serving (FastAPI + uvicorn). Loaded lazily when --api is used.
try:
    from fastapi import FastAPI
    import uvicorn
    HAS_FASTAPI = True
except ImportError:
    HAS_FASTAPI = False

# Redis support
try:
    import redis
    HAS_REDIS = True
except ImportError:
    HAS_REDIS = False

# Sound playing support
try:
    import winsound  # Windows
    HAS_WINSOUND = True
except ImportError:
    HAS_WINSOUND = False
    try:
        import os
        if sys.platform == "darwin":  # macOS
            HAS_OS_SYSTEM = True
        else:
            HAS_OS_SYSTEM = True  # Linux - use system beep
    except:
        HAS_OS_SYSTEM = False

# Suppress SSL warnings (Kotak URLs often use self-signed / corporate certs)
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# IST helpers: server runs in UTC; force Indian Standard Time for Redis timestamps.
_IST = timezone(timedelta(hours=5, minutes=30))

def now_ist() -> datetime:
    return datetime.now(_IST)



# Get the directory where this script is located
# Handle both direct execution and module import cases
try:
    SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
except NameError:
    # Fallback if __file__ is not available (rare case)
    SCRIPT_DIR = os.path.dirname(os.path.abspath(sys.argv[0]))

# Try to infer project root / outputs location flexibly:
# - If an "outputs" directory exists alongside the script, prefer that.
# - Otherwise fall back to the parent directory (useful when script is in python_scripts/).
DEFAULT_PROJECT_ROOT = os.path.dirname(SCRIPT_DIR)
if os.path.isdir(os.path.join(SCRIPT_DIR, "outputs")):
    PROJECT_ROOT = SCRIPT_DIR
else:
    PROJECT_ROOT = DEFAULT_PROJECT_ROOT

# OUTPUT_DIR is resolved under the chosen project root
OUTPUT_DIR = os.path.join(PROJECT_ROOT, "outputs")  # Directory containing processed expiry CSV files from process_expiry_data.py

# How close to the mid-point between two strikes we require for "near middle" logic
MIDPOINT_TOLERANCE_POINTS = 5.0  # as per your preference

# How many ITM/OTM strikes to include around ATM on each side
NEAR_ATM_STRIKE_COUNT = 4

# Alert parameters
PE_PRICE_THRESHOLD_PERCENT = 18.0  # 18% difference from low for PE price alert
NEAR_ATM_OI_DIFF_THRESHOLD_PERCENT = 16.0  # 16% difference threshold for Near-ATM OI comparison

# ---------------------------------------------------------------------------
# EMBEDDED WebSocket Binary Protocol (from Kotak Neo - no SDK required)
# ---------------------------------------------------------------------------

# WebSocket protocol constants
MAX_SCRIPS = 100
topic_list = {}  # Global topic list for WebSocket data
ws = None  # Global WebSocket connection for acknowledgements

FieldTypes = {'FLOAT32': 1, 'LONG': 2, 'DATE': 3, 'STRING': 4}
TRASH_VAL = -2147483648
STRING_INDEX = {'NAME': 51, 'SYMBOL': 52, 'EXCHG': 53, 'TSYMBOL': 54}
DEPTH_INDEX = {"MULTIPLIER": 32, "PRECISION": 33}

BinRespTypes = {
    "CONNECTION_TYPE": 1, "THROTTLING_TYPE": 2, "ACK_TYPE": 3,
    "SUBSCRIBE_TYPE": 4, "UNSUBSCRIBE_TYPE": 5, "DATA_TYPE": 6,
    "CHPAUSE_TYPE": 7, "CHRESUME_TYPE": 8, "SNAPSHOT": 9, "OPC_SUBSCRIBE": 10
}

BinRespStat = {"OK": "K", "NOT_OK": "N"}
ResponseTypes = {"SNAP": 83, "UPDATE": 85}
STAT = {"OK": "Ok", "NOT_OK": "NotOk"}

RespTypeValues = {
    "CONN": "cn", "SUBS": "sub", "UNSUBS": "unsub", "SNAP": "snap",
    "CHANNELR": "cr", "CHANNELP": "cp", "OPC": "opc"
}

RespCodes = {
    'SUCCESS': 200, 'CONNECTION_FAILED': 11001, 'CONNECTION_INVALID': 11002,
    'SUBSCRIPTION_FAILED': 11011, 'UNSUBSCRIPTION_FAILED': 11012,
    'SNAPSHOT_FAILED': 11013, 'CHANNELP_FAILED': 11031, 'CHANNELR_FAILED': 11032
}

TopicTypes = {"SCRIP": "sf", "INDEX": "if", "DEPTH": "dp"}
SCRIP_PREFIX = "sf"
INDEX_PREFIX = "if"
DEPTH_PREFIX = "dp"

INDEX_INDEX = {
    "LTP": 2, "CLOSE": 3, "CHANGE": 10, "PERCHANGE": 11,
    "MULTIPLIER": 8, "PRECISION": 9
}

SCRIP_INDEX = {
    "VOLUME": 4, "LTP": 5, "CLOSE": 21, "VWAP": 13,
    "MULTIPLIER": 23, "PRECISION": 24, "CHANGE": 25,
    "PERCHANGE": 26, "TURNOVER": 27
}


def leadingZero(a):
    return "0" + str(a) if a < 10 else str(a)


def getFormatDate(a):
    date = datetime.fromtimestamp(a)
    return "{}/{}/{} {}:{}:{}".format(
        leadingZero(date.day), leadingZero(date.month), date.year,
        leadingZero(date.hour), leadingZero(date.minute), leadingZero(date.second)
    )


class ByteData:
    def __init__(self, c):
        self.pos = 0
        self.bytes = [0] * c
        self.startOfMsg = 0

    def markStartOfMsg(self):
        self.startOfMsg = self.pos
        self.pos += 2

    def markEndOfMsg(self):
        len_val = (self.pos - self.startOfMsg - 2)
        self.bytes[self.startOfMsg] = ((len_val >> 8) & 255)
        self.bytes[self.startOfMsg + 1] = (len_val & 255)

    def getBytes(self):
        return bytearray(self.bytes)

    def appendByte(self, d):
        self.bytes[self.pos] = d
        self.pos += 1

    def appendShort(self, d):
        self.bytes[self.pos] = ((d >> 8) & 255)
        self.pos += 1
        self.bytes[self.pos] = (d & 255)
        self.pos += 1

    def appendInt(self, d):
        self.bytes[self.pos] = ((d >> 24) & 255)
        self.pos += 1
        self.bytes[self.pos] = ((d >> 16) & 255)
        self.pos += 1
        self.bytes[self.pos] = ((d >> 8) & 255)
        self.pos += 1
        self.bytes[self.pos] = (d & 255)
        self.pos += 1

    def append_string(self, d):
        for char in d:
            self.bytes[self.pos] = ord(char)
            self.pos += 1

    def appendByteArr(self, e, d):
        for i in range(d):
            self.bytes[self.pos] = e[i]
            self.pos += 1


def DataType(c, d):
    return {"name": c, "type": d}


# Index mapping
INDEX_MAPPING = [None] * 55
INDEX_MAPPING[0] = DataType("ftm0", FieldTypes.get("DATE"))
INDEX_MAPPING[1] = DataType("dtm1", FieldTypes.get("DATE"))
INDEX_MAPPING[INDEX_INDEX["LTP"]] = DataType("iv", FieldTypes.get("FLOAT32"))
INDEX_MAPPING[INDEX_INDEX["CLOSE"]] = DataType("ic", FieldTypes.get("FLOAT32"))
INDEX_MAPPING[4] = DataType("tvalue", FieldTypes.get("DATE"))
INDEX_MAPPING[5] = DataType("highPrice", FieldTypes.get("FLOAT32"))
INDEX_MAPPING[6] = DataType("lowPrice", FieldTypes.get("FLOAT32"))
INDEX_MAPPING[7] = DataType("openingPrice", FieldTypes.get("FLOAT32"))
INDEX_MAPPING.append(DataType("mul", FieldTypes.get("LONG")))
INDEX_MAPPING[INDEX_INDEX["PRECISION"]] = DataType("prec", FieldTypes.get("LONG"))
INDEX_MAPPING[INDEX_INDEX["CHANGE"]] = DataType("cng", FieldTypes.get("FLOAT32"))
INDEX_MAPPING[INDEX_INDEX["PERCHANGE"]] = DataType("nc", FieldTypes.get("STRING"))
INDEX_MAPPING[STRING_INDEX["NAME"]] = DataType("name", FieldTypes.get("STRING"))
INDEX_MAPPING[STRING_INDEX["SYMBOL"]] = DataType("tk", FieldTypes.get("STRING"))
INDEX_MAPPING[STRING_INDEX["EXCHG"]] = DataType("e", FieldTypes.get("STRING"))
INDEX_MAPPING[STRING_INDEX["TSYMBOL"]] = DataType("ts", FieldTypes.get("STRING"))

# Scrip mapping
SCRIP_MAPPING = [None] * 100
SCRIP_MAPPING[0] = DataType("ftm0", FieldTypes["DATE"])
SCRIP_MAPPING[1] = DataType("dtm1", FieldTypes["DATE"])
SCRIP_MAPPING[2] = DataType("fdtm", FieldTypes["DATE"])
SCRIP_MAPPING[3] = DataType("ltt", FieldTypes["DATE"])
SCRIP_MAPPING[SCRIP_INDEX["VOLUME"]] = DataType("v", FieldTypes["LONG"])
SCRIP_MAPPING[SCRIP_INDEX["LTP"]] = DataType("ltp", FieldTypes["FLOAT32"])
SCRIP_MAPPING[6] = DataType("ltq", FieldTypes["LONG"])
SCRIP_MAPPING[7] = DataType("tbq", FieldTypes["LONG"])
SCRIP_MAPPING[8] = DataType("tsq", FieldTypes["LONG"])
SCRIP_MAPPING[9] = DataType("bp", FieldTypes["FLOAT32"])
SCRIP_MAPPING[10] = DataType("sp", FieldTypes["FLOAT32"])
SCRIP_MAPPING[11] = DataType("bq", FieldTypes["LONG"])
SCRIP_MAPPING[12] = DataType("bs", FieldTypes["LONG"])
SCRIP_MAPPING[SCRIP_INDEX["VWAP"]] = DataType("ap", FieldTypes["FLOAT32"])
SCRIP_MAPPING[14] = DataType("lo", FieldTypes["FLOAT32"])
SCRIP_MAPPING[15] = DataType("h", FieldTypes["FLOAT32"])
SCRIP_MAPPING[16] = DataType("lcl", FieldTypes["FLOAT32"])
SCRIP_MAPPING[17] = DataType("ucl", FieldTypes["FLOAT32"])
SCRIP_MAPPING[18] = DataType("yh", FieldTypes["FLOAT32"])
SCRIP_MAPPING[19] = DataType("yl", FieldTypes["FLOAT32"])
SCRIP_MAPPING[20] = DataType("op", FieldTypes["FLOAT32"])
SCRIP_MAPPING[SCRIP_INDEX["CLOSE"]] = DataType("c", FieldTypes["FLOAT32"])
SCRIP_MAPPING[22] = DataType("oi", FieldTypes["LONG"])
SCRIP_MAPPING[SCRIP_INDEX["MULTIPLIER"]] = DataType("mul", FieldTypes["LONG"])
SCRIP_MAPPING[SCRIP_INDEX["PRECISION"]] = DataType("prec", FieldTypes["LONG"])
SCRIP_MAPPING[SCRIP_INDEX["CHANGE"]] = DataType("cng", FieldTypes["FLOAT32"])
SCRIP_MAPPING[SCRIP_INDEX["PERCHANGE"]] = DataType("nc", FieldTypes["STRING"])
SCRIP_MAPPING[SCRIP_INDEX["TURNOVER"]] = DataType("to", FieldTypes["FLOAT32"])
SCRIP_MAPPING[STRING_INDEX["NAME"]] = DataType("name", FieldTypes["STRING"])
SCRIP_MAPPING[STRING_INDEX["SYMBOL"]] = DataType("tk", FieldTypes["STRING"])
SCRIP_MAPPING[STRING_INDEX["EXCHG"]] = DataType("e", FieldTypes["STRING"])
SCRIP_MAPPING[STRING_INDEX["TSYMBOL"]] = DataType("ts", FieldTypes["STRING"])


class TopicData:
    def __init__(self, feed_type):
        self.feedType = feed_type
        self.exchange = None
        self.symbol = None
        self.tSymbol = None
        self.multiplier = 1
        self.precision = 2
        self.precisionValue = 100
        self.jsonArray = None
        self.fieldDataArray = [None] * 100
        self.updatedFieldsArray = [None] * 100
        self.fieldDataArray[STRING_INDEX["NAME"]] = feed_type

    def setLongValues(self, index_val, value):
        if self.fieldDataArray[index_val] != value and value != TRASH_VAL:
            self.fieldDataArray[index_val] = value
            self.updatedFieldsArray[index_val] = True

    def prepareCommonData(self):
        self.updatedFieldsArray[STRING_INDEX["NAME"]] = True
        self.updatedFieldsArray[STRING_INDEX["EXCHG"]] = True
        self.updatedFieldsArray[STRING_INDEX["SYMBOL"]] = True

    def setStringValues(self, e, d):
        if e == STRING_INDEX["SYMBOL"]:
            self.symbol = d
            self.fieldDataArray[STRING_INDEX["SYMBOL"]] = d
        elif e == STRING_INDEX["EXCHG"]:
            self.exchange = d
            self.fieldDataArray[STRING_INDEX["EXCHG"]] = d
        elif e == STRING_INDEX["TSYMBOL"]:
            self.tSymbol = d
            self.fieldDataArray[STRING_INDEX["TSYMBOL"]] = d
            self.updatedFieldsArray[STRING_INDEX["TSYMBOL"]] = True


class ScripTopicData(TopicData):
    def __init__(self):
        super().__init__(TopicTypes["SCRIP"])
        self.precision = None
        self.precisionValue = None
        self.multiplier = None

    def setMultiplierAndPrec(self):
        if self.updatedFieldsArray[SCRIP_INDEX["PRECISION"]]:
            self.precision = self.fieldDataArray[SCRIP_INDEX["PRECISION"]]
            self.precisionValue = pow(10, self.precision)
        if self.updatedFieldsArray[SCRIP_INDEX["MULTIPLIER"]]:
            self.multiplier = self.fieldDataArray[SCRIP_INDEX["MULTIPLIER"]]

    def prepareData(self, type=None):
        self.prepareCommonData()
        precesionFormat = "{:." + str(self.precision) + "f}"
        if self.updatedFieldsArray[SCRIP_INDEX["LTP"]] or self.updatedFieldsArray[SCRIP_INDEX["CLOSE"]]:
            ltp = self.fieldDataArray[SCRIP_INDEX["LTP"]]
            close = self.fieldDataArray[SCRIP_INDEX["CLOSE"]]
            if ltp is not None and close is not None:
                change = ltp - close
                self.fieldDataArray[SCRIP_INDEX["CHANGE"]] = change
                self.updatedFieldsArray[SCRIP_INDEX["CHANGE"]] = True
                self.fieldDataArray[SCRIP_INDEX["PERCHANGE"]] = precesionFormat.format((change / close * 100))
                self.updatedFieldsArray[SCRIP_INDEX["PERCHANGE"]] = True
        jsonRes = {}
        for index in range(len(SCRIP_MAPPING)):
            dataType = SCRIP_MAPPING[index]
            val = self.fieldDataArray[index]
            if self.updatedFieldsArray[index] and val is not None and dataType:
                if dataType["type"] == FieldTypes["FLOAT32"]:
                    val = precesionFormat.format(val / (self.multiplier * self.precisionValue))
                elif dataType["type"] == FieldTypes["DATE"]:
                    val = getFormatDate(val)
                jsonRes[dataType["name"]] = str(val)
        self.updatedFieldsArray = [None] * 100
        if type is not None:
            jsonRes["request_type"] = type
        return jsonRes


class IndexTopicData(TopicData):
    def __init__(self):
        super().__init__(TopicTypes["INDEX"])
        self.updatedFieldsArray = [None] * 100
        self.multiplier = None
        self.precision = None
        self.precisionValue = None

    def setMultiplierAndPrec(self):
        if self.updatedFieldsArray[INDEX_INDEX["PRECISION"]]:
            self.precision = self.fieldDataArray[INDEX_INDEX["PRECISION"]]
            self.precisionValue = 10 ** self.precision
        if self.updatedFieldsArray[INDEX_INDEX["MULTIPLIER"]]:
            self.multiplier = self.fieldDataArray[INDEX_INDEX["MULTIPLIER"]]

    def prepareData(self, type=None):
        self.prepareCommonData()
        if self.updatedFieldsArray[INDEX_INDEX["LTP"]] or self.updatedFieldsArray[INDEX_INDEX["CLOSE"]]:
            ltp = self.fieldDataArray[INDEX_INDEX["LTP"]]
            close = self.fieldDataArray[INDEX_INDEX["CLOSE"]]
            if ltp is not None and close is not None:
                change = ltp - close
                self.fieldDataArray[INDEX_INDEX["CHANGE"]] = change
                self.updatedFieldsArray[INDEX_INDEX["CHANGE"]] = True
                per_change = round(change / close * 100, self.precision)
                self.fieldDataArray[INDEX_INDEX["PERCHANGE"]] = per_change
                self.updatedFieldsArray[INDEX_INDEX["PERCHANGE"]] = True
        json_res = {}
        for index in range(len(INDEX_MAPPING)):
            data_type = INDEX_MAPPING[index]
            val = self.fieldDataArray[index]
            if self.updatedFieldsArray[index] and val is not None and data_type is not None:
                if data_type["type"] == FieldTypes["FLOAT32"]:
                    val = round(val / (self.multiplier * self.precisionValue), self.precision)
                elif data_type["type"] == FieldTypes["DATE"]:
                    val = getFormatDate(val)
                json_res[data_type["name"]] = str(val)
        self.updatedFieldsArray = [None] * 100
        if type is not None:
            json_res["request_type"] = type
        return json_res


def buf2long(a):
    """Convert bytes to long integer (big-endian)"""
    b = bytearray(a)
    val = 0
    leng = len(b)
    for i in range(leng):
        j = leng - 1 - i
        val += b[j] << (i * 8)
    return val if val < 2 ** 31 else val - 2 ** 32


def buf2string(a):
    """Convert bytes to string"""
    return bytes(a).decode('utf-8', errors='ignore')


def send_json_arr_resp(a):
    """Wrap response in JSON array"""
    return json.dumps([a])


def get_acknowledgement_req(a):
    """Create acknowledgment request"""
    buffer = ByteData(11)
    buffer.markStartOfMsg()
    buffer.appendByte(BinRespTypes["ACK_TYPE"])
    buffer.appendByte(1)
    buffer.appendByte(1)
    buffer.appendShort(4)
    buffer.appendInt(a)
    buffer.markEndOfMsg()
    return buffer.getBytes()


def is_scrip_ok(a):
    """Check if scrip count is within limits"""
    scrips_count = len(a.split("&"))
    if scrips_count > MAX_SCRIPS:
        print("Maximum scrips allowed per request is " + str(MAX_SCRIPS))
        return False
    return True


def getScripByteArray(c, a):
    """Convert scrip string to byte array"""
    if c and c[-1] == "&":
        c = c[:-1]
    scripArray = c.split("&")
    scripsCount = len(scripArray)
    dataLen = 0
    for index in range(scripsCount):
        scripArray[index] = a + "|" + scripArray[index]
        dataLen += len(scripArray[index]) + 1
    bytes_arr = [0] * (dataLen + 2)
    pos = 0
    bytes_arr[pos] = (scripsCount >> 8) & 255
    pos += 1
    bytes_arr[pos] = scripsCount & 255
    pos += 1
    for index in range(scripsCount):
        currScrip = scripArray[index]
        scripLen = len(currScrip)
        bytes_arr[pos] = scripLen & 255
        pos += 1
        for strIndex in range(scripLen):
            bytes_arr[pos] = ord(currScrip[strIndex])
            pos += 1
    return bytes_arr


def prepareConnectionRequest2(a, c):
    """Prepare connection request with JWT and Redis key"""
    src = "JS_API"
    srcLen = len(src)
    jwtLen = len(a)
    redisLen = len(c)
    buffer = ByteData(srcLen + jwtLen + redisLen + 13)
    buffer.markStartOfMsg()
    buffer.appendByte(BinRespTypes["CONNECTION_TYPE"])
    buffer.appendByte(3)
    buffer.appendByte(1)
    buffer.appendShort(jwtLen)
    buffer.append_string(a)
    buffer.appendByte(2)
    buffer.appendShort(redisLen)
    buffer.append_string(c)
    buffer.appendByte(3)
    buffer.appendShort(srcLen)
    buffer.append_string(src)
    buffer.markEndOfMsg()
    return buffer.getBytes()


def prepareSubsUnSubsRequest(scrips, subscribe_type, scrip_prefix, channel_num):
    """Prepare subscription/unsubscription request"""
    if not is_scrip_ok(scrips):
        return None
    dataArr = getScripByteArray(scrips, scrip_prefix)
    buffer = ByteData(len(dataArr) + 11)
    buffer.markStartOfMsg()
    buffer.appendByte(subscribe_type)
    buffer.appendByte(2)
    buffer.appendByte(1)
    buffer.appendShort(len(dataArr))
    buffer.appendByteArr(dataArr, len(dataArr))
    buffer.appendByte(2)
    buffer.appendShort(1)
    buffer.appendByte(int(channel_num))
    buffer.markEndOfMsg()
    return buffer.getBytes()


class HSWrapper:
    def __init__(self):
        self.counter = 0
        self.ack_num = 0

    def getNewTopicData(self, c):
        """Create new topic data based on feed type"""
        feed_type, *_ = c.split("|")
        topic = None
        if feed_type == TopicTypes.get("SCRIP"):
            topic = ScripTopicData()
        elif feed_type == TopicTypes.get("INDEX"):
            topic = IndexTopicData()
        return topic

    def getStatus(self, c, d):
        """Extract status from binary message"""
        status = BinRespStat.get("NOT_OK")
        field_count = buf2long(c[d:d + 1])
        d += 1
        if field_count > 0:
            fld = buf2long(c[d:d + 1])
            d = d + 1
            field_length = buf2long(c[d:d + 2])
            d += 2
            status = buf2string(c[d:d + field_length])
            d += field_length
        return status

    def parseData(self, e):
        """Parse binary WebSocket message"""
        global topic_list, ws
        pos = 0
        packetsCount = buf2long(e[pos:2])
        pos += 2
        type = int.from_bytes(e[pos:pos + 1], 'big')
        pos += 1
        
        if type == BinRespTypes.get("CONNECTION_TYPE"):
            jsonRes = {}
            fCount = int.from_bytes(e[pos:pos + 1], 'big')
            pos += 1
            if fCount >= 2:
                fid1 = int.from_bytes(e[pos:pos + 1], 'big')
                pos += 1
                valLen = int.from_bytes(e[pos:pos + 2], 'big')
                pos += 2
                status = e[pos:pos + valLen].decode('utf-8')
                pos += valLen
                fid1 = int.from_bytes(e[pos:pos + 1], 'big')
                pos += 1
                valLen = int.from_bytes(e[pos:pos + 2], 'big')
                pos += 2
                ackCount = int.from_bytes(e[pos:pos + valLen], 'big')
                if status == BinRespStat.get("OK"):
                    jsonRes['stat'] = STAT.get("OK")
                    jsonRes['type'] = RespTypeValues.get("CONN")
                    jsonRes['msg'] = "successful"
                    jsonRes['stCode'] = RespCodes.get("SUCCESS")
                elif status == BinRespStat.get("NOT_OK"):
                    jsonRes['stat'] = STAT.get("NOT_OK")
                    jsonRes['type'] = RespTypeValues.get("CONN")
                    jsonRes['msg'] = "failed"
                    jsonRes['stCode'] = RespCodes.get("CONNECTION_FAILED")
                self.ack_num = ackCount
            elif fCount == 1:
                fid1 = int.from_bytes(e[pos:pos + 1], 'big')
                pos += 1
                valLen = int.from_bytes(e[pos:pos + 2], 'big')
                pos += 2
                status = e[pos:pos + valLen].decode('utf-8')
                pos += valLen
                if status == BinRespStat.get("OK"):
                    jsonRes['stat'] = STAT.get("OK")
                    jsonRes['type'] = RespTypeValues.get("CONN")
                    jsonRes['msg'] = "successful"
                    jsonRes['stCode'] = RespCodes.get("SUCCESS")
                elif status == BinRespStat.get("NOT_OK"):
                    jsonRes['stat'] = STAT.get("NOT_OK")
                    jsonRes['type'] = RespTypeValues.get("CONN")
                    jsonRes['msg'] = "failed"
                    jsonRes['stCode'] = RespCodes.get("CONNECTION_FAILED")
            else:
                jsonRes['stat'] = STAT.get("NOT_OK")
                jsonRes['type'] = RespTypeValues.get("CONN")
                jsonRes['msg'] = "invalid field count"
                jsonRes['stCode'] = RespCodes.get("CONNECTION_INVALID")
            return send_json_arr_resp(jsonRes)
        else:
            if type == BinRespTypes.get("DATA_TYPE"):
                msg_num = 0
                if self.ack_num > 0:
                    self.counter += 1
                    msg_num = buf2long(e[pos: pos + 4])
                    pos += 4
                    if self.counter == self.ack_num:
                        req = get_acknowledgement_req(msg_num)
                        if ws:
                            ws.send(req, 0x2)
                            self.counter = 0
                h = []
                g = buf2long(e[pos: pos + 2])
                pos += 2
                for n in range(g):
                    pos += 2
                    c = buf2long(e[pos: pos + 1])
                    pos += 1
                    if c == ResponseTypes.get("SNAP"):
                        f = buf2long(e[pos: pos + 4])
                        pos += 4
                        name_len = buf2long(e[pos: pos + 1])
                        pos += 1
                        topic_name = buf2string(e[pos: pos + name_len])
                        pos += name_len
                        d = self.getNewTopicData(topic_name)
                        if d:
                            topic_list[f] = d
                            fcount = buf2long(e[pos: pos + 1])
                            pos += 1
                            for index in range(fcount):
                                fvalue = buf2long(e[pos: pos + 4])
                                d.setLongValues(index, fvalue)
                                pos += 4
                            d.setMultiplierAndPrec()
                            fcount = buf2long(e[pos: pos + 1])
                            pos += 1
                            for index in range(fcount):
                                fid = buf2long(e[pos: pos + 1])
                                pos += 1
                                data_len = buf2long(e[pos: pos + 1])
                                pos += 1
                                str_val = buf2string(e[pos: pos + data_len])
                                pos += data_len
                                d.setStringValues(fid, str_val)
                            h.append(d.prepareData("SNAP"))
                    else:
                        if c == ResponseTypes.get("UPDATE"):
                            f = buf2long(e[pos: pos + 4])
                            pos += 4
                            d = topic_list.get(f)
                            if not d:
                                pass  # Topic not available
                            else:
                                fcount = buf2long(e[pos:pos + 1])
                                pos += 1
                                for index in range(fcount):
                                    fvalue = buf2long(e[pos:pos + 4])
                                    d.setLongValues(index, fvalue)
                                    pos += 4
                            if d:
                                h.append(d.prepareData("SUB"))
                return h
            else:
                if type == BinRespTypes.get("SUBSCRIBE_TYPE") or type == BinRespTypes.get("UNSUBSCRIBE_TYPE"):
                    status = self.getStatus(e, pos)
                    json_res = {}
                    if status == BinRespStat.get("OK"):
                        json_res["stat"] = STAT.get("OK")
                        json_res["type"] = RespTypeValues.get("SUBS") if type == BinRespTypes.get("SUBSCRIBE_TYPE") else RespTypeValues.get("UNSUBS")
                        json_res["msg"] = "successful"
                        json_res["stCode"] = RespCodes.get("SUCCESS")
                    elif status == BinRespStat.get("NOT_OK"):
                        json_res["stat"] = STAT.get("NOT_OK")
                        if type == BinRespTypes.get("SUBSCRIBE_TYPE"):
                            json_res["type"] = RespTypeValues.get("SUBS")
                            json_res["msg"] = "subscription failed"
                            json_res["stCode"] = RespCodes.get("SUBSCRIPTION_FAILED")
                        else:
                            json_res["type"] = RespTypeValues.get("UNSUBS")
                            json_res["msg"] = "unsubscription failed"
                            json_res["stCode"] = RespCodes.get("UNSUBSCRIPTION_FAILED")
                    return send_json_arr_resp(json_res)
                else:
                    if type == BinRespTypes.get("SNAPSHOT"):
                        status = self.getStatus(e, pos)
                        json_res = {}
                        if status == BinRespStat.get("OK"):
                            json_res["stat"] = STAT.get("OK")
                            json_res["type"] = RespTypeValues.get("SNAP")
                            json_res["msg"] = "successful"
                            json_res["stCode"] = RespCodes.get("SUCCESS")
                        elif status == BinRespStat.get("NOT_OK"):
                            json_res["stat"] = STAT.get("NOT_OK")
                            json_res["type"] = RespTypeValues.get("SNAP")
                            json_res["msg"] = "failed"
                            json_res["stCode"] = RespCodes.get("SNAPSHOT_FAILED")
                        return send_json_arr_resp(json_res)
                    else:
                        return None


# ---------------------------------------------------------------------------
# Redis Storage Integration
# ---------------------------------------------------------------------------

class RedisStorer:
    """Handles pushing live data to Redis if enabled."""
    def __init__(self, enabled=False, host='localhost', port=6379, db=0):
        self.enabled = enabled and HAS_REDIS
        self.host = host
        self.port = port
        self.db = db
        self.r = None
        
        if self.enabled:
            try:
                self.r = redis.Redis(host=self.host, port=self.port, db=self.db, decode_responses=True)
                # Test connection
                self.r.ping()
                print(f"✅ Connected to Redis at {self.host}:{self.port} (db {self.db})")
            except Exception as e:
                print(f"❌ Failed to connect to Redis: {e}")
                self.enabled = False

    def push_snapshot(self, index, data):
        """Push a JSON snapshot of the current state for the given index."""
        if not self.enabled or self.r is None:
            return
        
        try:
            # Main snapshot for the index
            key = f"trading:oi:{index.lower()}:snapshot"
            self.r.set(key, json.dumps(data))
            
            # Individual fast-access keys
            self.r.set(f"trading:oi:{index.lower()}:spot", data.get("spot", 0.0))
            self.r.set(f"trading:oi:{index.lower()}:pcr", data.get("ratio", 0.0))
            self.r.set(f"trading:oi:{index.lower()}:last_update", data.get("timestamp", ""))
            
            # Update rolling history (with session rotation and duplicate detection)
            self.push_history(index, data)
            
        except Exception as e:
            print(f"⚠️ Redis push error: {e}")

    def push_history(self, index, data):
        """
        Manages rolling history with special logic:
        1. Keep last record of previous day (archive rotation).
        2. Don't push duplicates (if all data except timestamp is identical).
        3. Cap at 500 entries.
        """
        if not self.enabled or self.r is None:
            return
            
        try:
            history_key = f"trading:oi:{index.lower()}:history"
            
            # 1. Fetch the last entry to check for Session Rotation and Duplicates
            last_entry_json = self.r.lindex(history_key, -1)
            
            if last_entry_json:
                last_entry = json.loads(last_entry_json)
                
                # A. Session Rotation: If last item is from a previous day, keep only that one
                last_date = last_entry.get("date")
                current_date = now_ist().strftime("%Y-%m-%d")
                
                if last_date and last_date != current_date:
                    print(f"🔄 Redis History: New session detected. Keeping last record from {last_date} for reference.")
                    self.r.ltrim(history_key, -1, -1)
                    # Refresh last_entry after trim
                    last_entry_json = self.r.lindex(history_key, -1)
                    if last_entry_json:
                        last_entry = json.loads(last_entry_json)
                
                # B. Duplicate Detection: Compare data (ignoring timestamp and date)
                # Create copies for comparison to avoid modifying the original data
                ignore_keys = ["timestamp", "date"]
                new_comp = {k: v for k, v in data.items() if k not in ignore_keys}
                old_comp = {k: v for k, v in last_entry.items() if k not in ignore_keys}
                
                if new_comp == old_comp:
                    # Data hasn't changed, skip push
                    return

            # C. Push new data
            # Ensure the daily date is included in the snapshot for rotation logic
            data_with_date = data.copy()
            if "date" not in data_with_date:
                data_with_date["date"] = now_ist().strftime("%Y-%m-%d")
                
            self.r.rpush(history_key, json.dumps(data_with_date))
            
            # D. Maintenance: Keep only last 500 entries
            self.r.ltrim(history_key, -500, -1)
            
        except Exception as e:
            print(f"⚠️ Redis history error: {e}")

    def push_expensiveness(self, index, data):
        """Push expensiveness/cheapness detection results."""
        if not self.enabled or self.r is None:
            return
        
        try:
            key = f"trading:oi:{index.lower()}:expensiveness"
            self.r.set(key, json.dumps(data))
        except Exception as e:
            print(f"⚠️ Redis expensiveness push error: {e}")

    def push_full_chain(self, index, data):
        """
        Store full option chain quotes in a Redis Hash.
        Match by strike price and organize CE/PE data together.
        """
        if not self.enabled or self.r is None:
            return
            
        try:
            # Hash where key is strike price and value is JSON of both CE and PE
            hash_key = f"trading:oi:{index.lower()}:live_quotes"
            
            # Group by strike price
            strike_groups = {}
            quotes = data.get("quotes", {})
            strike_map = data.get("strike_type_to_token", {})
            
            # All available strikes
            strikes = sorted(set(s for s, t in strike_map.keys()))
            
            for s in strikes:
                token_ce = strike_map.get((s, "CE"))
                token_pe = strike_map.get((s, "PE"))
                
                ce_data = quotes.get(token_ce, {}) if token_ce else {}
                pe_data = quotes.get(token_pe, {}) if token_pe else {}

                # In continuous mode, quotes are stored as {"ltp","high","low","oi","last_quote":{...}}
                # In one-shot mode, quotes are often raw dicts from WebSocket.
                ce_raw = ce_data.get("last_quote") if isinstance(ce_data, dict) else None
                pe_raw = pe_data.get("last_quote") if isinstance(pe_data, dict) else None
                ce_src = ce_raw if isinstance(ce_raw, dict) else (ce_data if isinstance(ce_data, dict) else {})
                pe_src = pe_raw if isinstance(pe_raw, dict) else (pe_data if isinstance(pe_data, dict) else {})

                def _num(dct, *keys):
                    for k in keys:
                        if k in dct and dct[k] not in (None, "", "N/A"):
                            try:
                                return float(dct[k])
                            except (TypeError, ValueError):
                                pass
                    return 0.0
                
                # Simple summary for UI consumption
                strike_json = {
                    "strike": s,
                    "ce": {
                        "ltp": ce_data.get("ltp", 0.0),
                        "open": _num(ce_src, "op", "open", "openingPrice", "opening_price", "open_price"),
                        "oi": ce_data.get("oi", 0.0),
                        "chg": ce_data.get("cng", 0.0),
                        "pct": ce_data.get("nc", "0.0")
                    },
                    "pe": {
                        "ltp": pe_data.get("ltp", 0.0),
                        "open": _num(pe_src, "op", "open", "openingPrice", "opening_price", "open_price"),
                        "oi": pe_data.get("oi", 0.0),
                        "chg": pe_data.get("cng", 0.0),
                        "pct": pe_data.get("nc", "0.0")
                    }
                }
                strike_groups[str(s)] = json.dumps(strike_json)
            
            # Pipeline updates for efficiency
            pipe = self.r.pipeline()
            # Clear old and set new (or just HMSET which overwrites)
            # Using delete first ensures old strikes are gone if chain shifts
            pipe.delete(hash_key)
            if strike_groups:
                pipe.hset(hash_key, mapping=strike_groups)
            pipe.execute()
            
        except Exception as e:
            print(f"⚠️ Redis full chain push error: {e}")


# ---------------------------------------------------------------------------
# Kotak session (login + WebSocket quotes)
# ---------------------------------------------------------------------------

class KotakSession:
    """
    Self-contained wrapper for Kotak Neo authentication and WebSocket quotes.
    
    All WebSocket functionality is embedded (no external helper files required).

    This class:
    - Loads credentials from b.txt
    - Performs TOTP + MPIN login
    - Exposes helpers for:
        - get_index_spot("NIFTY" / "SENSEX") - WebSocket ONLY (embedded)
        - get_option_quotes(tokens, exchange_segment) - WebSocket ONLY (embedded)
        - get_option_quotes_persistent(tokens, exchange_segment) - Persistent WebSocket (embedded)
    """

    def __init__(self, credentials_path: str = "b.txt") -> None:
        self.credentials_path = credentials_path
        self.consumer_key: Optional[str] = None
        self.consumer_secret: Optional[str] = None
        self.mobile_number: Optional[str] = None
        self.totp_secret: Optional[str] = None
        self.mpin: Optional[str] = None
        self.ucc: Optional[str] = None

        self.base_url: Optional[str] = None
        self.view_token: Optional[str] = None
        self.view_sid: Optional[str] = None
        self.edit_token: Optional[str] = None
        self.edit_sid: Optional[str] = None
        self.bearer_token: Optional[str] = None

    # ----------------- credential + auth helpers ---------------------------

    def load_credentials(self) -> bool:
        """Load credentials from b.txt (same format as other scripts)."""
        credentials: Dict[str, str] = {}
        try:
            with open(self.credentials_path, "r") as f:
                for line in f:
                    line = line.strip()
                    if "=" in line and not line.startswith("#"):
                        key, value = line.split("=", 1)
                        key = key.strip()
                        value = value.strip()
                        if value.startswith('"') and value.endswith('"'):
                            value = value[1:-1]
                        elif value.startswith("'") and value.endswith("'"):
                            value = value[1:-1]
                        credentials[key] = value

            self.consumer_key = credentials.get("KOTAK_CONSUMER_KEY")
            self.consumer_secret = credentials.get("KOTAK_CONSUMER_SECRET") or ""
            self.mobile_number = credentials.get("KOTAK_MOBILE_NUMBER")
            self.totp_secret = credentials.get("KOTAK_TOTP_SECRET")
            self.mpin = credentials.get("KOTAK_MPIN")
            self.ucc = credentials.get("KOTAK_UCC")

            if not all([self.consumer_key, self.mobile_number, self.totp_secret, self.mpin, self.ucc]):
                print("❌ Missing required credentials in b.txt")
                return False
            return True
        except Exception as e:
            print(f"❌ Error loading credentials from {self.credentials_path}: {e}")
            return False

    def get_base_url(self) -> bool:
        """Get base URL from UCC (same as in your existing scripts)."""
        try:
            url = "https://lapi.kotaksecurities.com/algo-user/v5/get-base-url"
            params = {"id": self.ucc}
            resp = requests.get(url, params=params, timeout=15)
            if resp.status_code == 200:
                data = resp.json().get("data", {})
                base = data.get("baseURL")
                if base:
                    self.base_url = base if base.endswith("/") else base + "/"
                    print(f"✓ Base URL: {self.base_url}")
                    return True
        except Exception as e:
            print(f"⚠️  Failed to get base URL: {e}")
        print("⚠️  Proceeding without base URL (quotes API may not work).")
        return False

    def totp_login(self) -> bool:
        """Step 1: TOTP login (tradeApiLogin)."""
        try:
            totp_code = pyotp.TOTP(self.totp_secret).now()
        except Exception as e:
            print(f"❌ Failed to generate TOTP: {e}")
            return False

        mobile = self.mobile_number
        if isinstance(mobile, str) and not mobile.startswith("+") and len(mobile) == 10 and mobile.isdigit():
            mobile = "+91" + mobile

        url = "https://mis.kotaksecurities.com/login/1.0/tradeApiLogin"
        headers = {
            "Content-Type": "application/json",
            "Authorization": self.consumer_key,
            "neo-fin-key": "neotradeapi",
        }
        body = {"mobileNumber": mobile, "ucc": self.ucc, "totp": totp_code}

        try:
            resp = requests.post(url, headers=headers, json=body, verify=False, timeout=20)
        except Exception as e:
            print(f"❌ TOTP login error: {e}")
            return False

        if resp.status_code != 200:
            print(f"❌ TOTP login failed: {resp.status_code} - {resp.text[:200]}")
            return False

        data = resp.json().get("data", {})
        if data.get("status") != "success":
            print(f"❌ TOTP login failed: {data}")
            return False

        self.view_token = data.get("token")
        self.view_sid = data.get("sid")
        print("✓ TOTP login successful")
        return True

    def totp_validate(self) -> bool:
        """Step 2: MPIN validation (tradeApiValidate)."""
        url = "https://mis.kotaksecurities.com/login/1.0/tradeApiValidate"
        headers = {
            "Content-Type": "application/json",
            "Authorization": self.consumer_key,
            "sid": self.view_sid,
            "Auth": self.view_token,
            "neo-fin-key": "neotradeapi",
        }
        body = {"mpin": self.mpin}
        try:
            resp = requests.post(url, headers=headers, json=body, verify=False, timeout=20)
        except Exception as e:
            print(f"❌ MPIN validate error: {e}")
            return False

        if resp.status_code != 200:
            print(f"❌ MPIN validate failed: {resp.status_code} - {resp.text[:200]}")
            return False

        data = resp.json().get("data", {})
        if data.get("status") != "success":
            print(f"❌ MPIN validate failed: {data}")
            return False

        self.edit_token = data.get("token")
        self.edit_sid = data.get("sid") or self.view_sid
        base = data.get("baseUrl")
        if base:
            self.base_url = base if base.endswith("/") else base + "/"
        print("✓ MPIN validate successful")
        return True

    def session_init_for_bearer_token(self) -> bool:
        """Optional: get OAuth bearer token for quotes."""
        import base64

        if not self.consumer_secret:
            print("⚠️  No consumer_secret - will use edit_token for quotes.")
            return True

        if self.base_url and "gw-napi" in self.base_url:
            session_base = "https://napi.kotaksecurities.com/"
        else:
            session_base = "https://mnapi.kotaksecurities.com/"

        url = f"{session_base}oauth2/token"
        credentials = f"{self.consumer_key}:{self.consumer_secret}"
        b64 = base64.b64encode(credentials.encode("ascii")).decode("ascii")

        headers = {"Content-Type": "application/json", "Authorization": f"Basic {b64}"}
        body = {"grant_type": "client_credentials"}

        try:
            resp = requests.post(url, headers=headers, json=body, verify=False, timeout=20)
            if resp.status_code == 200:
                data = resp.json()
                self.bearer_token = data.get("access_token")
                print("✓ Session init successful (bearer_token obtained)")
                return True
            print(f"⚠️  Session init failed: {resp.status_code} - {resp.text[:120]}")
        except Exception as e:
            print(f"⚠️  Session init error: {e}")
        # Not fatal, we can still use edit_token
        return True

    def authenticate(self) -> bool:
        print("\n🔐 Authenticating with Kotak Neo...")
        if not self.load_credentials():
            return False
        self.get_base_url()
        self.session_init_for_bearer_token()
        if not self.totp_login():
            return False
        if not self.totp_validate():
            return False
        print("✅ Authentication complete.\n")
        return True

    # ----------------- quotes helpers --------------------------------------

    @staticmethod
    def _safe_get(d: Dict, *keys, default="N/A"):
        for k in keys:
            if k in d and d[k] not in (None, "", "N/A"):
                return d[k]
        return default

    # Global (process-lifetime) cache to preserve last known OI per token
    OI_CACHE: Dict[str, Dict[str, float]] = {}

    @staticmethod
    def _extract_numeric_token(token_value: str) -> str:
        """Normalize tokens coming from WebSocket (may include sf|/if| prefixes)."""
        token_str = str(token_value).strip()
        if "|" in token_str:
            candidate = token_str.split("|")[-1]
            if candidate.isdigit():
                return candidate
        match = re.search(r"(\d+)$", token_str)
        return match.group(1) if match else token_str

    def get_index_quote(self, index: str) -> Optional[Dict[str, float]]:
        """
        Get current index quote via WebSocket ONLY (embedded, no external files).
        
        index: "NIFTY" or "SENSEX"
        """
        idx = index.upper()
        
        if idx not in ("NIFTY", "SENSEX"):
            print(f"❌ Unsupported index: {index}")
            return None
        
        print(f"📡 Fetching {idx} quote via WebSocket...")
        
        ws_url = "wss://mlhsm.kotaksecurities.com"
        index_quote: Optional[Dict[str, float]] = None
        connection_ok = False
        subscription_ok = False
        data_received = threading.Event()
        hs_wrapper = HSWrapper()
        global ws, topic_list
        
        # Determine symbol based on index
        if idx == "NIFTY":
            scrips = "nse_cm|Nifty 50"
            symbol_name = "Nifty 50"
        else:  # SENSEX
            scrips = "bse_cm|SENSEX"
            symbol_name = "SENSEX"
        
        def on_open(ws_conn):
            nonlocal connection_ok
            global ws
            ws = ws_conn
            print("  ✓ WebSocket connected")
            conn_bytes = prepareConnectionRequest2(self.edit_token, self.edit_sid)
            ws_conn.send(conn_bytes, opcode=0x2)
        
        def on_message(ws_conn, message):
            nonlocal connection_ok, subscription_ok, index_quote
            global ws
            ws = ws_conn
            
            try:
                if not isinstance(message, bytes):
                    return
                
                parsed = hs_wrapper.parseData(message)
                
                if parsed:
                    if isinstance(parsed, str):
                        try:
                            parsed = json.loads(parsed)
                        except:
                            pass
                    
                    if isinstance(parsed, list) and len(parsed) > 0:
                        item = parsed[0]
                        if isinstance(item, dict):
                            if item.get('type') == 'cn' and item.get('stat') == 'Ok':
                                connection_ok = True
                                time.sleep(0.3)
                                
                                # Subscribe to index
                                sub_bytes = prepareSubsUnSubsRequest(
                                    scrips,
                                    BinRespTypes["SUBSCRIBE_TYPE"],
                                    INDEX_PREFIX,
                                    2
                                )
                                if sub_bytes:
                                    ws_conn.send(sub_bytes, opcode=0x2)
                                    print(f"  ✓ Subscribed to {idx}")
                            
                            elif item.get('type') in ['sub', 'ifs']:
                                subscription_ok = True
                                print("  ✓ Subscription acknowledged")
                    
                    # Get index data
                    if isinstance(parsed, list):
                        for item in parsed:
                            if isinstance(item, dict):
                                token = item.get('tk')
                                if token == symbol_name or not token:
                                    ltp = item.get("iv") or item.get("ltp")
                                    if ltp is None:
                                        continue
                                    try:
                                        ltp_f = float(ltp)
                                    except (ValueError, TypeError):
                                        continue
                                    if ltp_f <= 0:
                                        continue

                                    # OHLC + change fields are part of INDEX_MAPPING (openingPrice/highPrice/lowPrice/ic/cng/nc)
                                    def _to_float(v):
                                        try:
                                            return float(v)
                                        except (ValueError, TypeError):
                                            return 0.0

                                    index_quote = {
                                        "ltp": ltp_f,
                                        "open": _to_float(item.get("openingPrice") or item.get("open")),
                                        "high": _to_float(item.get("highPrice") or item.get("high")),
                                        "low": _to_float(item.get("lowPrice") or item.get("low")),
                                        "close": _to_float(item.get("ic") or item.get("close")),
                                        "change": _to_float(item.get("cng") or item.get("change")),
                                        "per_change": _to_float(item.get("nc") or item.get("perChange") or item.get("per_change")),
                                    }

                                    print(f"  ✓ {idx} CMP: ₹{ltp_f:.2f}")
                                    data_received.set()
                                    ws_conn.close()
                                    return
                                        
            except Exception as e:
                print(f"  ⚠️  Error parsing message: {e}")
        
        def on_error(ws, error):
            print(f"  ⚠️  WebSocket error: {error}")
        
        def on_close(ws, close_status_code, close_msg):
            pass
        
        try:
            ws_connection = websocket.WebSocketApp(
                ws_url,
                on_open=on_open,
                on_message=on_message,
                on_error=on_error,
                on_close=on_close
            )
            
            ws_thread = threading.Thread(
                target=lambda: ws_connection.run_forever(
                    sslopt={"cert_reqs": ssl.CERT_NONE},
                    ping_interval=30,
                    ping_timeout=10
                ),
                daemon=True
            )
            ws_thread.start()
            
            # Wait for data (max 10 seconds)
            if not data_received.wait(timeout=10):
                print("  ⚠️  Timeout waiting for index CMP")
            
            try:
                ws_connection.close()
            except:
                pass
            
            return index_quote
            
        except Exception as e:
            print(f"  ❌ WebSocket error: {e}")
            return None

    def get_index_spot(self, index: str) -> Optional[float]:
        """Backward compatible wrapper returning only index CMP."""
        q = self.get_index_quote(index)
        if not q:
            return None
        return q.get("ltp")

    def get_index_spot_persistent(self, index: str):
        """
        Open a persistent WebSocket for index spot. Returns (ws_connection, spot_state_dict)
        spot_state_dict["value"] is updated live.
        Also updates: open/high/low/close/change/per_change when available.
        """
        idx = index.upper()
        if idx not in ("NIFTY", "SENSEX"):
            print(f"❌ Unsupported index: {index}")
            return None
        
        ws_url = "wss://mlhsm.kotaksecurities.com"
        hs_wrapper = HSWrapper()
        spot_state: Dict[str, Optional[float]] = {
            "value": None,
            "open": None,
            "high": None,
            "low": None,
            "close": None,
            "change": None,
            "per_change": None,
        }
        subscription_event = threading.Event()
        global ws, topic_list
        
        if idx == "NIFTY":
            scrips = "nse_cm|Nifty 50"
            symbol_name = "Nifty 50"
        else:
            scrips = "bse_cm|SENSEX"
            symbol_name = "SENSEX"
        
        def on_open(ws_conn):
            global ws
            ws = ws_conn
            conn_bytes = prepareConnectionRequest2(self.edit_token, self.edit_sid)
            ws_conn.send(conn_bytes, opcode=0x2)
        
        def on_message(ws_conn, message):
            global ws
            ws = ws_conn
            try:
                if not isinstance(message, bytes):
                    return
                
                parsed = hs_wrapper.parseData(message)
                if parsed:
                    if isinstance(parsed, str):
                        try:
                            parsed = json.loads(parsed)
                        except:
                            pass
                    
                    if isinstance(parsed, list) and len(parsed) > 0:
                        item = parsed[0]
                        if isinstance(item, dict):
                            if item.get("type") == "cn" and item.get("stat") == "Ok":
                                # subscribe to index
                                sub_bytes = prepareSubsUnSubsRequest(
                                    scrips,
                                    BinRespTypes["SUBSCRIBE_TYPE"],
                                    INDEX_PREFIX,
                                    2,
                                )
                                if sub_bytes:
                                    ws_conn.send(sub_bytes, opcode=0x2)
                            
                            elif item.get("type") in ["sub", "ifs"]:
                                subscription_event.set()
                    
                    if isinstance(parsed, list):
                        for item in parsed:
                            if isinstance(item, dict):
                                token = item.get("tk")
                                if token == symbol_name or not token:
                                    ltp = item.get("iv") or item.get("ltp")
                                    if ltp:
                                        try:
                                            spot_state["value"] = float(ltp)
                                        except (ValueError, TypeError):
                                            pass
                                    # Optional OHLC/change fields (may arrive with the same index packets)
                                    def _set_float(key: str, v):
                                        if v is None or v == "":
                                            return
                                        try:
                                            spot_state[key] = float(v)
                                        except (ValueError, TypeError):
                                            pass

                                    _set_float("open", item.get("openingPrice") or item.get("open"))
                                    _set_float("high", item.get("highPrice") or item.get("high"))
                                    _set_float("low", item.get("lowPrice") or item.get("low"))
                                    _set_float("close", item.get("ic") or item.get("close"))
                                    _set_float("change", item.get("cng") or item.get("change"))
                                    # nc sometimes comes as string/number; keep as float if possible
                                    _set_float("per_change", item.get("nc") or item.get("perChange") or item.get("per_change"))
            except Exception:
                pass
        
        def on_error(ws_conn, error):
            print(f"  ⚠️  Index WebSocket error: {error}")
        
        def on_close(ws_conn, close_status_code, close_msg):
            print("  ℹ️  Index WebSocket closed")
        
        try:
            ws_connection = websocket.WebSocketApp(
                ws_url,
                on_open=on_open,
                on_message=on_message,
                on_error=on_error,
                on_close=on_close,
            )
            ws_thread = threading.Thread(
                target=lambda: ws_connection.run_forever(
                    sslopt={"cert_reqs": ssl.CERT_NONE},
                    ping_interval=30,
                    ping_timeout=10,
                ),
                daemon=True,
            )
            ws_thread.start()
            
            # Wait briefly for subscription
            subscription_event.wait(timeout=5)
            if not subscription_event.is_set():
                print("⚠️  Index subscription not acknowledged (will still keep connection alive).")
            else:
                print(f"✓ Index subscription live for {idx}")
            
            return ws_connection, spot_state
        except Exception as e:
            print(f"❌ Could not start persistent index WebSocket: {e}")
            return None

    def get_option_quotes(
        self, tokens: List[str], exchange_segment: str
    ) -> Dict[str, Dict]:
        """
        Fetch option quotes via WebSocket ONLY (embedded, no external files).

        tokens: list of pSymbol values (instrument token strings)
        exchange_segment: "nse_fo" or "bse_fo"
        """
        if not tokens:
            return {}

        seg = exchange_segment.lower()
        if seg not in ("nse_fo", "bse_fo"):
            print(f"❌ Unsupported exchange segment: {exchange_segment}")
            return {}

        print(f"📡 Fetching {len(tokens)} tokens via WebSocket...")
        
        ws_url = "wss://mlhsm.kotaksecurities.com"
        all_quotes: Dict[str, Dict] = {}
        connection_ok = False
        subscription_ok = False
        hs_wrapper = HSWrapper()
        global ws, topic_list
        
        token_set = {str(t).strip() for t in tokens}
        token_lookup: Dict[str, str] = {}
        for t in tokens:
            raw = str(t).strip()
            normalized = self._extract_numeric_token(raw)
            token_lookup[raw] = raw
            token_lookup[normalized] = raw
        tokens_collected_set = set()
        data_received_event = threading.Event()
        
        def on_open(ws_conn):
            nonlocal connection_ok
            global ws
            ws = ws_conn
            print("  ✓ WebSocket connected")
            conn_bytes = prepareConnectionRequest2(self.edit_token, self.edit_sid)
            ws_conn.send(conn_bytes, opcode=0x2)
            print("  ✓ Connection message sent")
        
        def on_message(ws_conn, message):
            nonlocal connection_ok, subscription_ok, all_quotes, tokens_collected_set
            global ws
            ws = ws_conn
            
            try:
                if not isinstance(message, bytes):
                    return
                
                parsed = hs_wrapper.parseData(message)
                
                if parsed:
                    if isinstance(parsed, str):
                        try:
                            parsed = json.loads(parsed)
                        except:
                            pass
                    
                    # Connection/subscription responses
                    if isinstance(parsed, list) and len(parsed) > 0:
                        item = parsed[0]
                        if isinstance(item, dict):
                            if item.get('type') == 'cn' and item.get('stat') == 'Ok':
                                connection_ok = True
                                print("  ✓ Connection acknowledged")
                                time.sleep(0.3)
                                
                                # Subscribe to all tokens at once
                                scrips = "&".join([f"{seg}|{token}" for token in tokens])
                                sub_bytes = prepareSubsUnSubsRequest(
                                    scrips,
                                    BinRespTypes["SUBSCRIBE_TYPE"],
                                    SCRIP_PREFIX,
                                    2
                                )
                                if sub_bytes:
                                    ws_conn.send(sub_bytes, opcode=0x2)
                                    print(f"  ✓ Subscribed to {len(tokens)} tokens")
                            
                            elif item.get('type') in ['sub', 'mws']:
                                if not subscription_ok:
                                    subscription_ok = True
                                    print("  ✓ Subscription acknowledged")
                    
                    # Market data updates
                    if isinstance(parsed, list):
                        for item in parsed:
                            if isinstance(item, dict):
                                token = item.get('tk')
                                if token:
                                    token_str = str(token).strip()
                                    normalized = self._extract_numeric_token(token_str)
                                    matched_token_key = (
                                        token_lookup.get(token_str) or token_lookup.get(normalized)
                                    )
                                    
                                    if matched_token_key:
                                        # Preserve OI timestamp/carry-forward
                                        oi_val = item.get("oi")
                                        if oi_val is not None:
                                            try:
                                                oi_float = float(oi_val)
                                                item["oi"] = oi_float
                                                item["oi_timestamp"] = time.time()
                                                KotakSession.OI_CACHE[matched_token_key] = {
                                                    "oi": oi_float,
                                                    "ts": item["oi_timestamp"],
                                                }
                                            except (ValueError, TypeError):
                                                pass
                                        else:
                                            # carry-forward from cache if available
                                            cached = KotakSession.OI_CACHE.get(matched_token_key)
                                            if cached:
                                                item["oi"] = cached.get("oi")
                                                item["oi_timestamp"] = cached.get("ts")
                                        
                                        all_quotes[matched_token_key] = item
                                        if matched_token_key not in tokens_collected_set:
                                            tokens_collected_set.add(matched_token_key)
                                            if len(tokens_collected_set) % 20 == 0 or len(tokens_collected_set) == len(token_set):
                                                print(f"  ✓ Collected: {len(tokens_collected_set)}/{len(token_set)} tokens...")
                                            if len(tokens_collected_set) == 1:
                                                data_received_event.set()
                                            if len(tokens_collected_set) >= len(token_set):
                                                print(f"  ✓ All {len(token_set)} tokens collected!")
                                                data_received_event.set()
                                                return
                                        
            except Exception as e:
                print(f"  ⚠️  Error parsing message: {e}")
        
        def on_error(ws, error):
            print(f"  ⚠️  WebSocket error: {error}")
        
        def on_close(ws, close_status_code, close_msg):
            print("  ✓ WebSocket closed")
        
        try:
            ws_connection = websocket.WebSocketApp(
                ws_url,
                on_open=on_open,
                on_message=on_message,
                on_error=on_error,
                on_close=on_close
            )
            
            ws_thread = threading.Thread(
                target=lambda: ws_connection.run_forever(
                    sslopt={"cert_reqs": ssl.CERT_NONE},
                    ping_interval=30,
                    ping_timeout=10
                ),
                daemon=True
            )
            ws_thread.start()
            
            # Wait for subscription
            subscription_wait_start = time.time()
            while not subscription_ok and (time.time() - subscription_wait_start) < 5:
                time.sleep(0.1)
            
            if not subscription_ok:
                print("  ⚠️  Subscription not acknowledged")
                try:
                    ws_connection.close()
                except:
                    pass
                return {}
            
            # Wait for data
            timeout = 30
            print(f"  ⏳ Waiting for data (max {timeout:.1f}s)...")
            data_received_event.wait(timeout=min(timeout, 10))
            
            if len(tokens_collected_set) > 0:
                remaining_time = timeout - (time.time() - subscription_wait_start)
                if remaining_time > 0:
                    time.sleep(min(2.0, remaining_time))
            
            if len(tokens_collected_set) < len(token_set):
                missing = len(token_set) - len(tokens_collected_set)
                print(f"  ⚠️  Collected {len(tokens_collected_set)}/{len(token_set)} tokens ({missing} missing)")
            else:
                print(f"  ✓ All tokens collected!")

            try:
                ws_connection.close()
                time.sleep(0.1)
            except:
                pass
            
            return all_quotes
            
        except Exception as e:
            print(f"  ❌ WebSocket error: {e}")
            import traceback
            traceback.print_exc()
            return {}

    def get_option_quotes_persistent(
        self, tokens: List[str], exchange_segment: str
    ) -> Optional[Tuple]:
        """
        Open persistent WebSocket connection for option quotes (for continuous mode).
        
        Returns: (ws_connection, quotes_dict) tuple where quotes_dict is updated continuously
        Returns: None if failed
        """
        if not tokens:
            return None

        seg = exchange_segment.lower()
        if seg not in ("nse_fo", "bse_fo"):
            return None

        ws_url = "wss://mlhsm.kotaksecurities.com"
        all_quotes: Dict[str, Dict] = {}
        connection_ok = False
        subscription_ok = False
        hs_wrapper = HSWrapper()
        global ws, topic_list
        
        token_set = {str(t).strip() for t in tokens}
        token_lookup: Dict[str, str] = {}
        for t in tokens:
            raw = str(t).strip()
            normalized = self._extract_numeric_token(raw)
            token_lookup[raw] = raw
            token_lookup[normalized] = raw
        subscription_event = threading.Event()
        data_received_event = threading.Event()
        tokens_collected = set()
        
        def on_open(ws_conn):
            nonlocal connection_ok
            global ws
            ws = ws_conn
            conn_bytes = prepareConnectionRequest2(self.edit_token, self.edit_sid)
            ws_conn.send(conn_bytes, opcode=0x2)
        
        def on_message(ws_conn, message):
            nonlocal connection_ok, subscription_ok, tokens_collected
            global ws
            ws = ws_conn
            
            try:
                if not isinstance(message, bytes):
                    return
                
                parsed = hs_wrapper.parseData(message)
                
                if parsed:
                    if isinstance(parsed, str):
                        try:
                            parsed = json.loads(parsed)
                        except:
                            pass
                    
                    if isinstance(parsed, list) and len(parsed) > 0:
                        item = parsed[0]
                        if isinstance(item, dict):
                            if item.get('type') == 'cn' and item.get('stat') == 'Ok':
                                connection_ok = True
                                time.sleep(0.3)
                                
                                scrips = "&".join([f"{seg}|{token}" for token in tokens])
                                sub_bytes = prepareSubsUnSubsRequest(
                                    scrips,
                                    BinRespTypes["SUBSCRIBE_TYPE"],
                                    SCRIP_PREFIX,
                                    2
                                )
                                if sub_bytes:
                                    ws_conn.send(sub_bytes, opcode=0x2)
                            
                            elif item.get('type') in ['sub', 'mws']:
                                if not subscription_ok:
                                    subscription_ok = True
                                    subscription_event.set()
                    
                    if isinstance(parsed, list):
                        for item in parsed:
                            if isinstance(item, dict):
                                token = item.get('tk')
                                if token:
                                    token_str = str(token).strip()
                                    normalized = self._extract_numeric_token(token_str)
                                    matched_token_key = (
                                        token_lookup.get(token_str) or token_lookup.get(normalized)
                                    )
                                    if matched_token_key:
                                        oi_val = item.get("oi")
                                        if oi_val is not None:
                                            try:
                                                oi_float = float(oi_val)
                                                item["oi"] = oi_float
                                                item["oi_timestamp"] = time.time()
                                                KotakSession.OI_CACHE[matched_token_key] = {
                                                    "oi": oi_float,
                                                    "ts": item["oi_timestamp"],
                                                }
                                            except (ValueError, TypeError):
                                                pass
                                        else:
                                            cached = KotakSession.OI_CACHE.get(matched_token_key)
                                            if cached:
                                                item["oi"] = cached.get("oi")
                                                item["oi_timestamp"] = cached.get("ts")
                                        all_quotes[matched_token_key] = item
                                        if matched_token_key not in tokens_collected:
                                            tokens_collected.add(matched_token_key)
                                            if len(tokens_collected) >= max(1, len(token_set) * 0.2):
                                                data_received_event.set()
                                        
            except Exception as e:
                pass
        
        def on_error(ws, error):
            # Log WebSocket errors for debugging
            print(f"  ⚠️  WebSocket error: {error}")
        
        def on_close(ws, close_status_code, close_msg):
            # Log when WebSocket closes unexpectedly
            if close_status_code:
                print(f"  ⚠️  WebSocket closed: code={close_status_code}, msg={close_msg}")
            else:
                print(f"  ℹ️  WebSocket closed normally")
        
        try:
            ws_connection = websocket.WebSocketApp(
                ws_url,
                on_open=on_open,
                on_message=on_message,
                on_error=on_error,
                on_close=on_close
            )
            
            ws_thread = threading.Thread(
                target=lambda: ws_connection.run_forever(
                    sslopt={"cert_reqs": ssl.CERT_NONE},
                    ping_interval=30,
                    ping_timeout=10
                ),
                daemon=True
            )
            ws_thread.start()
            
            # Wait for subscription acknowledgment (increased timeout for batch connections)
            if subscription_event.wait(timeout=15):
                return ws_connection, all_quotes
            else:
                print(f"  ⚠️  Subscription timeout after 15s")
                try:
                    ws_connection.close()
                except:
                    pass
                return None
            
        except Exception as e:
            return None


# ---------------------------------------------------------------------------
# Scrip master helpers (NIFTY / SENSEX options, current expiry)
# ---------------------------------------------------------------------------


def find_expiry_csv(index: str) -> str:
    """
    Find today's or latest processed expiry CSV from process_expiry_data.py output.
    
    Format: nifty_expiry_YYYYMMDD_EXPIRY.csv or sensex_bse_expiry_YYYYMMDD_EXPIRY.csv
    """
    # Check if OUTPUT_DIR exists
    if not os.path.exists(OUTPUT_DIR):
        raise FileNotFoundError(
            f"Output directory not found: {OUTPUT_DIR}\n"
            f"Please ensure the 'outputs' directory exists in the project root.\n"
            f"Run process_expiry_data.py first to generate the CSV files."
        )
    
    if not os.path.isdir(OUTPUT_DIR):
        raise NotADirectoryError(
            f"Output path exists but is not a directory: {OUTPUT_DIR}"
        )
    
    today_str = datetime.now().strftime("%Y%m%d")
    
    if index.upper() == "NIFTY":
        pattern_prefix = "nifty_expiry_"
    elif index.upper() == "SENSEX":
        pattern_prefix = "sensex_bse_expiry_"
    else:
        raise ValueError(f"Unsupported index: {index}")
    
    # Try today's file first
    pattern = os.path.join(OUTPUT_DIR, f"{pattern_prefix}{today_str}_*.csv")
    candidates = glob_glob(pattern)
    
    if not candidates:
        # Fallback to any file with this prefix
        pattern = os.path.join(OUTPUT_DIR, f"{pattern_prefix}*.csv")
        candidates = glob_glob(pattern)
    
    if not candidates:
        raise FileNotFoundError(
            f"No processed expiry CSV found in {OUTPUT_DIR} for {index}.\n"
            f"Please run process_expiry_data.py first to generate the CSV files.\n"
            f"Expected file pattern: {pattern_prefix}*.csv"
        )

    def extract_date_key(path: str) -> datetime:
        name = os.path.basename(path)
        try:
            # Format: nifty_expiry_YYYYMMDD_EXPIRY.csv
            parts = name.replace(".csv", "").split("_")
            if len(parts) >= 3:
                date_str = parts[2]  # YYYYMMDD
                return datetime.strptime(date_str, "%Y%m%d")
        except Exception:
            pass
        return datetime.min

    candidates.sort(key=extract_date_key, reverse=True)  # Latest first
    return candidates[0]


def glob_glob(pattern: str) -> List[str]:
    """Small wrapper around glob to avoid importing in multiple places."""
    import glob

    return glob.glob(pattern)


@dataclass
class OptionRow:
    token: str  # pSymbol
    option_type: str  # CE/PE
    strike: int
    expiry_code: str  # e.g. "30DEC25"


def load_options_for_index(index: str, redis_host='localhost', redis_port=6379) -> Tuple[List[OptionRow], str]:
    """
    Load all option rows from Redis.
    
    Reads from: kotak:expiry:nifty or kotak:expiry:sensex
    
    Returns:
        (list_of_options, selected_expiry_code)
    """
    index_name = index.upper()
    redis_key = f"kotak:expiry:{index_name.lower()}"
    
    print(f"📖 Reading expiry data for {index_name} from Redis key: {redis_key}")
    
    try:
        import redis
        r = redis.Redis(host=redis_host, port=redis_port, db=0, decode_responses=True)
        # Test connection
        r.ping()
        
        # Get JSON data
        raw_data = r.get(redis_key)
        if not raw_data:
            raise RuntimeError(f"Redis key '{redis_key}' is empty or not found.")
            
        data = json.loads(raw_data)
    except Exception as e:
        print(f"❌ Error connecting to Redis or loading {redis_key}: {e}")
        # Try local CSV if project root is reachable
        print(f"⚠️  Falling back to manual scrip master processing is not implemented yet in this helper.")
        raise RuntimeError(f"Could not load expiry data for {index_name} from Redis.")
    
    if not data or not isinstance(data, list):
        raise RuntimeError(f"Invalid data format in Redis for {index_name}")
    
    # Parse first record to get expiry code
    selected_expiry = data[0].get("Expiry", "N/A")
    print(f"\n📅 Using expiry from Redis: {selected_expiry}")
    
    # Build options list
    options: List[OptionRow] = []
    for row in data:
        try:
            strike = int(float(row.get("Strike Price")))
            token = str(row.get("pSymbol")).strip()
            opt_type = str(row.get("pOptionType")).strip().upper()
            
            if opt_type not in ("CE", "PE"):
                continue
                
            options.append(
                OptionRow(
                    token=token,
                    option_type=opt_type,
                    strike=strike,
                    expiry_code=selected_expiry,
                )
            )
        except (ValueError, KeyError, TypeError) as e:
            continue

    if not options:
        raise RuntimeError(f"No valid options found in Redis for {index_name}.")

    print(f"✅ Loaded {len(options)} options for {index_name} expiry {selected_expiry}")
    return options, selected_expiry




def update_live_oi_sheet(
    index: str,
    expiry: str,
    options: List[OptionRow],
    quotes: Dict[str, Dict],
    spot: float
) -> None:
    """
    Update the live OI sheet with current strike data.
    
    Creates/updates tabs: NIFTY_Live_OI or SENSEX_Live_OI
    """
    try:
        spreadsheet = setup_google_sheets()
        tab_name = f"{index.upper()}_Live_OI"
        
        # Try to get existing worksheet, create if doesn't exist
        try:
            worksheet = spreadsheet.worksheet(tab_name)
            print(f"  ✓ Found existing {tab_name} tab")
        except:
            worksheet = spreadsheet.add_worksheet(title=tab_name, rows=1000, cols=15)
            print(f"  ✓ Created new {tab_name} tab")
        
        # Prepare data
        timestamp = now_ist().strftime("%Y-%m-%d %H:%M:%S")
        
        # Metadata rows
        data = [
            ["Symbol", "Expiry", "Spot", "Last_Updated"],
            [index.upper(), expiry, f"{spot:.2f}", timestamp],
            [],  # Empty row
            # Column headers
            ["Strike", "Type", "Token", "OI", "LTP", "High", "Low", "Volume", "Change%"]
        ]
        
        # Add strike data
        for opt in sorted(options, key=lambda x: (x.strike, x.option_type)):
            q = quotes.get(opt.token, {})
            
            oi = q.get("oi", q.get("openInterest", q.get("open_interest", "N/A")))
            ltp = q.get("ltp", q.get("lastPrice", "N/A"))
            high = q.get("h", q.get("high", "N/A"))
            low = q.get("lo", q.get("low", "N/A"))
            volume = q.get("v", q.get("volume", "N/A"))
            change_pct = q.get("nc", q.get("percentChange", "N/A"))
            
            data.append([
                opt.strike,
                opt.option_type,
                opt.token,
                str(oi) if oi != "N/A" else "N/A",
                str(ltp) if ltp != "N/A" else "N/A",
                str(high) if high != "N/A" else "N/A",
                str(low) if low != "N/A" else "N/A",
                str(volume) if volume != "N/A" else "N/A",
                str(change_pct) if change_pct != "N/A" else "N/A"
            ])
        
        # Clear and update sheet
        worksheet.clear()
        worksheet.update(data, value_input_option='USER_ENTERED')
        
        print(f"  ✅ Updated {tab_name} with {len(options)} strikes")
        
    except Exception as e:
        print(f"  ⚠️  Failed to update live OI sheet: {e}")


def update_dashboard_sheet(
    index: str,
    expiry: str,
    spot: float,
    total_ce_oi: float,
    total_pe_oi: float,
    near_atm_ce_oi: float,
    near_atm_pe_oi: float,
    atm_strike: int,
    near_atm_strikes: Dict[str, List[int]],
    quotes: Dict[str, Dict],
    strike_type_to_token: Dict[Tuple[int, str], str],
    expensiveness_data: Optional[Dict] = None
) -> None:
    """
    Update the OI Dashboard sheet with summary metrics and historical data.
    
    Creates/updates tab: Live_OI_Analysis
    - Top section: Latest snapshot (always updated)
    - Bottom section: Historical log (appends new rows with timestamps)
    - Stale data detection: If last update >10 minutes, forces retry
    """
    try:
        spreadsheet = setup_google_sheets()
        tab_name = "Live_OI_Analysis"
        
        # Try to get existing worksheet, create if doesn't exist
        try:
            worksheet = spreadsheet.worksheet(tab_name)
            print(f"  ✓ Found existing {tab_name} tab")
        except:
            worksheet = spreadsheet.add_worksheet(title=tab_name, rows=1000, cols=15)
            print(f"  ✓ Created new {tab_name} tab")
        
        # Get current timestamp in IST (India Standard Time)
        from datetime import timedelta
        now_utc = datetime.utcnow()
        ist_offset = timedelta(hours=5, minutes=30)
        now = now_utc + ist_offset
        timestamp = now.strftime("%Y-%m-%d %H:%M:%S IST")
        
        # Check for stale data (>10 minutes since last update)
        try:
            # Read the last update timestamp from cell B6 (where we store it)
            last_update_str = worksheet.acell('B6').value
            if last_update_str:
                try:
                    # Remove " IST" suffix if present
                    timestamp_str = last_update_str.replace(" IST", "")
                    last_update = datetime.strptime(timestamp_str, "%Y-%m-%d %H:%M:%S")
                    time_diff = (now - last_update).total_seconds() / 60.0  # minutes
                    
                    if time_diff > 10:
                        print(f"  ⚠️  WARNING: Last update was {time_diff:.1f} minutes ago (>10 min threshold)")
                        print(f"  🔄 Forcing update to refresh stale data...")
                except ValueError:
                    # Invalid timestamp format, proceed with update
                    pass
        except Exception:
            # First time or error reading timestamp, proceed with update
            pass
        
        # Prepare summary data (top section - always overwritten)
        ce_pe_ratio = total_ce_oi / total_pe_oi if total_pe_oi > 0 else 0
        near_atm_diff = near_atm_ce_oi - near_atm_pe_oi
        near_atm_diff_pct = (near_atm_diff / near_atm_pe_oi * 100) if near_atm_pe_oi > 0 else 0
        
        # Helper function to get quote data
        def safe_get_num(q: Dict, *keys) -> float:
            for key in keys:
                val = q.get(key)
                if val is not None and val != "N/A":
                    try:
                        return float(val)
                    except:
                        pass
            return 0.0
        
        # Build summary section (rows 1-25 approximately)
        summary_data = [
            [f"🔴 LIVE OI ANALYSIS - {index.upper()}", "", "", "", "", "", "", "", "", ""],
            ["", "", "", "", "", "", "", "", "", ""],
            ["Index:", index.upper(), "Expiry:", expiry, "Spot:", f"{spot:.2f}", "Last Updated:", timestamp],
            ["", "", "", "", "", "", "", "", "", ""],
            ["═══ CURRENT SNAPSHOT ═══", "", "", "", "", "", "", "", "", ""],
            ["Last Update:", timestamp, "", "", "", "", "", "", "", ""],
            ["", "", "", "", "", "", "", "", "", ""],
            ["📊 TOTAL OI SUMMARY", "", "", "", "", "", "", "", "", ""],
            ["Total CE OI:", f"{total_ce_oi:,.0f}", "Total PE OI:", f"{total_pe_oi:,.0f}", "CE/PE Ratio:", f"{ce_pe_ratio:.3f}"],
            ["", "", "", "", "", "", "", "", "", ""],
            ["📍 NEAR-ATM OI (4 ITM + ATM + 4 OTM)", "", "", "", "", "", "", "", "", ""],
            ["Near-ATM CE:", f"{near_atm_ce_oi:,.0f}", "Near-ATM PE:", f"{near_atm_pe_oi:,.0f}", "Difference:", f"{near_atm_diff:,.0f}", "Diff %:", f"{near_atm_diff_pct:.2f}%"],
            ["", "", "", "", "", "", "", "", "", ""],
            ["💰 EXPENSIVENESS CHECK", "", "", "", "", "", "", "", "", ""],
        ]
        
        # Add expensiveness data
        if expensiveness_data:
            side = expensiveness_data["side"]
            strike = expensiveness_data.get("strike", "N/A")
            diff_points = expensiveness_data["diff_points"]
            diff_pct = expensiveness_data["diff_pct"]
            mode = expensiveness_data["mode"]
            ce_strike = expensiveness_data["ce_strike"]
            pe_strike = expensiveness_data["pe_strike"]
            ce_price = expensiveness_data["ce_price"]
            pe_price = expensiveness_data["pe_price"]
            
            if side == "NONE":
                summary_data.append(["Status:", "Both sides roughly equal", "", "", "", "", "", "", "", ""])
            else:
                summary_data.append(["Expensive Side:", side, "Strike:", str(strike), "Diff:", f"{diff_points:.2f} pts ({diff_pct:.2f}%)"])
            
            summary_data.append(["Mode:", mode, "CE Strike:", f"{ce_strike} @ ₹{ce_price:.2f}", "PE Strike:", f"{pe_strike} @ ₹{pe_price:.2f}"])
        else:
            summary_data.append(["Status:", "No check performed", "", "", "", "", "", "", "", ""])
        
        summary_data.extend([
            ["", "", "", "", "", "", "", "", "", ""],
            ["", "", "", "", "", "", "", "", "", ""],
            ["═══ HISTORICAL DATA LOG ═══", "", "", "", "", "", "", "", "", ""],
            ["", "", "", "", "", "", "", "", "", ""],
        ])
        
        # Historical data header (starts at row ~22)
        historical_header = [
            "Timestamp", "Spot", "ATM Strike", "Total CE OI", "Total PE OI", "CE/PE Ratio",
            "Near-ATM CE", "Near-ATM PE", "Near-ATM Diff %", "Expensive Side", "Mode"
        ]
        
        # Prepare historical row
        expensive_side = expensiveness_data.get("side", "N/A") if expensiveness_data else "N/A"
        mode = expensiveness_data.get("mode", "N/A") if expensiveness_data else "N/A"
        
        historical_row = [
            timestamp,
            f"{spot:.2f}",
            str(atm_strike),
            f"{total_ce_oi:,.0f}",
            f"{total_pe_oi:,.0f}",
            f"{ce_pe_ratio:.3f}",
            f"{near_atm_ce_oi:,.0f}",
            f"{near_atm_pe_oi:,.0f}",
            f"{near_atm_diff_pct:.2f}%",
            expensive_side,
            mode
        ]
        
        # Read existing data to preserve historical rows
        try:
            existing_data = worksheet.get_all_values()
            
            # Find where historical data starts (look for the header row)
            historical_start_row = None
            for i, row in enumerate(existing_data):
                if row and len(row) > 0 and row[0] == "Timestamp":
                    historical_start_row = i
                    break
            
            # If we found historical data, preserve it
            if historical_start_row is not None and len(existing_data) > historical_start_row + 1:
                # Get existing historical rows (skip the header)
                existing_historical = existing_data[historical_start_row + 1:]
                
                # Limit to last 500 rows to prevent sheet from growing too large
                max_historical_rows = 500
                if len(existing_historical) >= max_historical_rows:
                    existing_historical = existing_historical[-max_historical_rows + 1:]
                
                # Combine: summary + header + new row + existing rows
                final_data = summary_data + [historical_header] + [historical_row] + existing_historical
            else:
                # No existing historical data, start fresh
                final_data = summary_data + [historical_header] + [historical_row]
        except Exception as e:
            # Error reading existing data, start fresh
            print(f"  ⚠️  Could not read existing historical data: {e}")
            final_data = summary_data + [historical_header] + [historical_row]
        
        # Update the entire sheet
        worksheet.clear()
        worksheet.update(final_data, value_input_option='USER_ENTERED')
        
        # Count historical rows
        historical_row_count = len(final_data) - len(summary_data) - 1  # -1 for header
        print(f"  ✅ Updated {tab_name} | Historical rows: {historical_row_count}")
        
    except Exception as e:
        print(f"  ⚠️  Failed to update dashboard: {e}")
        import traceback
        traceback.print_exc()



# ---------------------------------------------------------------------------
# ATM / strike selection helpers
# ---------------------------------------------------------------------------


def find_atm_and_neighbors(strikes: List[int], spot: float) -> Tuple[int, Optional[int], Optional[int]]:
    """
    Returns:
      atm_strike, lower_strike, upper_strike
    lower/upper may be None at edges.
    """
    unique = sorted(set(strikes))
    if not unique:
        raise ValueError("No strikes available.")

    atm = min(unique, key=lambda x: abs(x - spot))
    idx = unique.index(atm)
    lower = unique[idx - 1] if idx > 0 else None
    upper = unique[idx + 1] if idx < len(unique) - 1 else None
    return atm, lower, upper


def select_near_atm_strikes(strikes: List[int], spot: float) -> Dict[str, List[int]]:
    """
    Select 4 ITM + ATM + 4 OTM for each of CE and PE.

    For CE: ITM if strike <= spot
    For PE: ITM if strike >= spot
    """
    unique = sorted(set(strikes))
    atm = min(unique, key=lambda x: abs(x - spot))

    ce_itm = [s for s in unique if s <= spot]
    ce_otm = [s for s in unique if s > spot]
    pe_itm = [s for s in unique if s >= spot]
    pe_otm = [s for s in unique if s < spot]

    ce_itm_sel = list(reversed(ce_itm))[:NEAR_ATM_STRIKE_COUNT]
    ce_itm_sel = list(reversed(ce_itm_sel))  # back to ascending
    ce_otm_sel = ce_otm[:NEAR_ATM_STRIKE_COUNT]

    pe_itm_sel = pe_itm[:NEAR_ATM_STRIKE_COUNT]
    pe_otm_sel = list(reversed(pe_otm))[:NEAR_ATM_STRIKE_COUNT]
    pe_otm_sel = list(reversed(pe_otm_sel))

    return {
        "ATM": [atm],
        "CE_ITM": ce_itm_sel,
        "CE_OTM": ce_otm_sel,
        "PE_ITM": pe_itm_sel,
        "PE_OTM": pe_otm_sel,
    }


def decide_comparison_strikes(
    spot: float, lower: Optional[int], atm: int, upper: Optional[int]
) -> Optional[Tuple[int, str, int, str, str]]:
    """
    Decide which strikes to compare for expensiveness, using your 3-band rule.

    Bands around a 50‑point grid of strikes (…, 26000, 26050, 26100, …):
      - ATM band (centered at atm):      spot in [atm - 10, atm + 10]
          -> compare CE(atm) vs PE(atm)
      - Lower middle band (between lower and atm):  spot in [mid_lower - 10, mid_lower + 10]
          -> compare CE(atm)  vs PE(lower)
      - Upper middle band (between atm and upper): spot in [mid_upper - 10, mid_upper + 10]
          -> compare CE(upper) vs PE(atm)

    Returns:
      (strike_ce, type_ce, strike_pe, type_pe, mode)
      mode: "ATM", "LOWER_MID" or "UPPER_MID"
    or None if no comparison should be done.
    """
    # 1) ATM band: spot within ±10 of atm  -> compare CE(atm) vs PE(atm)
    if abs(spot - atm) <= MIDPOINT_TOLERANCE_POINTS:
        return atm, "CE", atm, "PE", "ATM"

    # 2) Lower middle band: between lower and atm, centered at mid_lower
    if lower is not None:
        mid_lower = (lower + atm) / 2.0
        if abs(spot - mid_lower) <= MIDPOINT_TOLERANCE_POINTS:
            # Example: lower=26000, atm=26050, mid_lower=26025
            # -> compare 26050 CE vs 26000 PE
            return atm, "CE", lower, "PE", "LOWER_MID"

    # 3) Upper middle band: between atm and upper, centered at mid_upper
    if upper is not None:
        mid_upper = (atm + upper) / 2.0
        if abs(spot - mid_upper) <= MIDPOINT_TOLERANCE_POINTS:
            # Example: atm=26050, upper=26100, mid_upper=26075
            # -> compare 26100 CE vs 26050 PE
            return upper, "CE", atm, "PE", "UPPER_MID"

    # Otherwise: no comparison (outside all bands)
    return None


# ---------------------------------------------------------------------------
# Alert system (sound alerts based on OI and price conditions)
# ---------------------------------------------------------------------------


def build_expensiveness_redis_payload(
    spot: float,
    strikes: List[int],
    strike_type_to_token: Dict[Tuple[int, str], str],
    quotes: Dict[str, Dict],
    timestamp: str,
) -> Dict[str, Any]:
    # Build expensiveness payload for Redis.
    # Key requirement: use SAME spot + timestamp as the OI snapshot.

    out: Dict[str, Any] = {'timestamp': timestamp, 'spot': float(spot) if spot else 0.0}

    if not spot or spot <= 0:
        out['mode'] = 'NO_SPOT'
        return out

    atm, lower, upper = find_atm_and_neighbors(strikes, spot)
    out['atm_strike'] = atm

    comp = decide_comparison_strikes(spot, lower, atm, upper)

    def _ltp(tok: str) -> float:
        q = quotes.get(tok, {})
        v = q.get('ltp', 0.0)
        try:
            return float(v)
        except (TypeError, ValueError):
            return 0.0

    if not comp:
        out['mode'] = 'NO_COMPARISON'
        return out

    strike_ce, type_ce, strike_pe, type_pe, mode = comp
    token_ce = strike_type_to_token.get((strike_ce, type_ce))
    token_pe = strike_type_to_token.get((strike_pe, type_pe))

    out['mode'] = mode
    out['ce_strike'] = strike_ce
    out['pe_strike'] = strike_pe

    if not token_ce or not token_pe:
        out['note'] = 'Missing option tokens for comparison strikes'
        return out

    price_ce = _ltp(token_ce)
    price_pe = _ltp(token_pe)

    out['ce_price'] = price_ce
    out['pe_price'] = price_pe

    if price_ce <= 0 or price_pe <= 0:
        out['note'] = 'Waiting for LTP on comparison strikes'
        return out

    diff = abs(price_ce - price_pe)
    avg = (price_ce + price_pe) / 2.0
    diff_pct = diff / avg * 100.0 if avg != 0 else 0.0

    expensive_side = 'CE' if price_ce > price_pe else ('PE' if price_pe > price_ce else 'NONE')

    out['side'] = expensive_side
    out['diff_pts'] = diff
    out['diff_pct'] = diff_pct

    return out


def play_alert_sound():
    """Play alert sound (works on Windows, macOS, Linux)."""
    try:
        if HAS_WINSOUND:
            # Windows: use winsound
            winsound.Beep(1000, 500)  # Frequency 1000 Hz, duration 500ms
            time.sleep(0.2)
            winsound.Beep(1000, 500)  # Play twice for attention
        elif HAS_OS_SYSTEM:
            # macOS/Linux: use system beep
            os.system("echo -e '\a'")  # ASCII bell character
            time.sleep(0.2)
            os.system("echo -e '\a'")  # Play twice
        else:
            # Fallback: print to console
            print("\a\a")  # ASCII bell (may work on some terminals)
    except Exception as e:
        print(f"⚠️  Could not play alert sound: {e}")


def select_pe_strikes_for_alert(strikes: List[int], spot: float) -> Dict[str, List[int]]:
    """
    Select strikes for PE alert checking:
    - 3 OTM PE strikes (strikes below spot)
    - 1 ITM PE strike (strike above spot, closest to spot)
    """
    unique = sorted(set(strikes))
    
    # PE ITM: strikes >= spot (closest one)
    pe_itm = [s for s in unique if s >= spot]
    pe_itm_sel = pe_itm[:1] if pe_itm else []  # Only 1 ITM strike
    
    # PE OTM: strikes < spot (take 3 closest to spot)
    pe_otm = [s for s in unique if s < spot]
    pe_otm_sel = list(reversed(pe_otm))[:3]  # 3 OTM strikes closest to spot
    pe_otm_sel = list(reversed(pe_otm_sel))  # Back to ascending order
    
    return {
        "PE_ITM": pe_itm_sel,
        "PE_OTM": pe_otm_sel,
    }


def check_alert_conditions(
    index: str,
    options: List[OptionRow],
    spot: float,
    shared_quotes: Dict[str, Dict],
    strike_type_to_token: Dict[Tuple[int, str], str],
) -> Tuple[bool, List[Tuple[int, float, float, float]]]:
    """
    Check if alert conditions are met:
    1. Total CE OI > Total PE OI
    2. Near-ATM CE OI > Near-ATM PE OI
    3. Call side is expensive (CE price > PE price at ATM)
    4. PE strikes (3 OTM + 1 ITM) are within 18% of their low
    
    Returns:
        (True, details) if all conditions met (should play sound)
        (False, details) otherwise
    where details = List of tuples (strike, ltp, low, percent_from_low)
    """
    try:
        # Build quotes dict for calculations
        quotes_for_check = {}
        for opt in options:
            token_data = shared_quotes.get(opt.token, {})
            quotes_for_check[opt.token] = {
                "ltp": token_data.get("ltp", 0.0),
                "low": token_data.get("low", 0.0),
                "oi": token_data.get("oi", 0.0),
            }
        
        # Condition 1: Total CE OI > Total PE OI
        total_oi_ce = sum(
            quotes_for_check.get(opt.token, {}).get("oi", 0.0)
            for opt in options if opt.option_type == "CE"
        )
        total_oi_pe = sum(
            quotes_for_check.get(opt.token, {}).get("oi", 0.0)
            for opt in options if opt.option_type == "PE"
        )
        
        if total_oi_ce <= total_oi_pe:
            return False, []  # Condition 1 not met
        
        # Condition 2: Near-ATM CE OI > Near-ATM PE OI
        strikes = sorted({opt.strike for opt in options})
        near = select_near_atm_strikes(strikes, spot)
        
        ce_near_strikes = sorted(set(near["ATM"] + near["CE_ITM"] + near["CE_OTM"]))
        pe_near_strikes = sorted(set(near["ATM"] + near["PE_ITM"] + near["PE_OTM"]))
        
        ce_near_oi = sum(
            quotes_for_check.get(strike_type_to_token.get((s, "CE"), ""), {}).get("oi", 0.0)
            for s in ce_near_strikes
            if strike_type_to_token.get((s, "CE"))
        )
        pe_near_oi = sum(
            quotes_for_check.get(strike_type_to_token.get((s, "PE"), ""), {}).get("oi", 0.0)
            for s in pe_near_strikes
            if strike_type_to_token.get((s, "PE"))
        )
        
        if ce_near_oi <= pe_near_oi:
            return False, []  # Condition 2 not met
        
        # Condition 3: Call side is expensive (CE price > PE price at ATM)
        atm, _, _ = find_atm_and_neighbors(strikes, spot)
        token_ce_atm = strike_type_to_token.get((atm, "CE"))
        token_pe_atm = strike_type_to_token.get((atm, "PE"))
        
        if not token_ce_atm or not token_pe_atm:
            return False, []  # Missing ATM tokens
        
        price_ce = quotes_for_check.get(token_ce_atm, {}).get("ltp", 0.0)
        price_pe = quotes_for_check.get(token_pe_atm, {}).get("ltp", 0.0)
        
        if price_ce <= 0 or price_pe <= 0:
            return False, []  # Invalid prices
        
        if price_ce <= price_pe:
            return False, []  # Call side is not expensive (Condition 3 not met)
        
        # Condition 4: Check 3 OTM PE + 1 ITM PE strikes are within 18% of low
        pe_strikes = select_pe_strikes_for_alert(strikes, spot)
        pe_check_strikes = pe_strikes["PE_ITM"] + pe_strikes["PE_OTM"]
        
        if len(pe_check_strikes) < 4:
            return False, []  # Not enough PE strikes to check
        
        all_within_threshold = True
        failure_details: List[Tuple[int, str, float, float, float]] = []
        checked_strikes: List[Tuple[int, float, float, float]] = []  # (strike, ltp, low, percent_from_low)
        for strike in pe_check_strikes:
            token_pe = strike_type_to_token.get((strike, "PE"))
            if not token_pe:
                all_within_threshold = False
                failure_details.append((strike, "Missing token", 0.0, 0.0, 100.0))
                break
            
            quote = quotes_for_check.get(token_pe, {})
            ltp = quote.get("ltp", 0.0)
            low = quote.get("low", 0.0)
            
            if ltp <= 0 or low <= 0:
                all_within_threshold = False
                failure_details.append((strike, "Invalid price", ltp, low, 100.0))
                break
            
            # Check if price is within 18% of low
            # Formula: (low - ltp) / low <= 0.18
            # This means ltp >= low * 0.82 (price is at least 82% of low, i.e., within 18% difference)
            percent_from_low = ((low - ltp) / low) * 100.0 if low > 0 else 100.0
            checked_strikes.append((strike, ltp, low, percent_from_low))
            
            if percent_from_low > PE_PRICE_THRESHOLD_PERCENT:
                all_within_threshold = False
                failure_details.append((strike, "Below threshold", ltp, low, percent_from_low))
                break
        
        if not all_within_threshold:
            # Print detailed reason for easier debugging
            print("\n⚠️  PE low-check failed. Details:")
            for strike, reason, ltp, low, pct in failure_details:
                print(f"   Strike {strike} - {reason} - LTP {ltp:.2f}, Low {low:.2f}, Diff {pct:.2f}%")
            if not failure_details and checked_strikes:
                print("   (All strikes checked but condition still failed)")
            else:
                for strike, ltp, low, pct in checked_strikes:
                    print(f"   Strike {strike} - LTP {ltp:.2f}, Low {low:.2f}, Diff {pct:.2f}%")
            return False, checked_strikes  # Condition 4 not met
        
        # All conditions met - trigger alert!
        return True, checked_strikes
        
    except Exception as e:
        print(f"⚠️  Error checking alert conditions: {e}")
        return False, []


# ---------------------------------------------------------------------------
# OI + expensiveness calculation
# ---------------------------------------------------------------------------


def compute_oi_summary_and_expensiveness(
    index: str,
    options: List[OptionRow],
    spot: float,
    quotes: Dict[str, Dict],
) -> Dict:
    """Calculates all metrics and returns a results dictionary."""
    stale_warnings: List[str] = []
    # Build mapping: (strike, type) -> token
    strike_type_to_token: Dict[Tuple[int, str], str] = {}
    for opt in options:
        strike_type_to_token[(opt.strike, opt.option_type)] = opt.token

    # Critical tokens: within 500 pts of spot
    critical_tokens = {
        opt.token for opt in options if abs(opt.strike - spot) <= 500
    }

    strikes = sorted({opt.strike for opt in options})
    atm, lower, upper = find_atm_and_neighbors(strikes, spot)
    near = select_near_atm_strikes(strikes, spot)

    def safe_get_quote(token: str) -> Dict:
        return quotes.get(token, {})

    def safe_get_num(q: Dict, *keys) -> float:
        val = KotakSession._safe_get(q, *keys, default="N/A")
        try:
            return float(val)
        except Exception:
            return 0.0

    # Total OI across all strikes
    total_oi_ce = 0.0
    total_oi_pe = 0.0
    for opt in options:
        q = safe_get_quote(opt.token)
        oi = safe_get_num(q, "oi", "openInterest", "open_interest")
        if opt.option_type == "CE":
            total_oi_ce += oi
        else:
            total_oi_pe += oi

    # Near-ATM OI (4 ITM + ATM + 4 OTM) on each side
    def collect_oi_for_bucket(strike_list: List[int], opt_type: str) -> Tuple[float, List[Tuple[int, float]]]:
        total = 0.0
        rows: List[Tuple[int, float]] = []
        for s in strike_list:
            token = strike_type_to_token.get((s, opt_type))
            if not token:
                continue
            q = safe_get_quote(token)
            oi = safe_get_num(q, "oi", "openInterest", "open_interest")
            # track OI age if available
            ts = q.get("oi_timestamp")
            if ts and (time.time() - ts) > 300:
                stale_warnings.append(f"{opt_type} {s} OI last update {int((time.time()-ts)//60)} min ago")
            total += oi
            rows.append((s, oi))
        return total, rows

    ce_near_strikes = sorted(set(near["ATM"] + near["CE_ITM"] + near["CE_OTM"]))
    pe_near_strikes = sorted(set(near["ATM"] + near["PE_ITM"] + near["PE_OTM"]))

    ce_near_oi, ce_near_rows = collect_oi_for_bucket(ce_near_strikes, "CE")
    pe_near_oi, pe_near_rows = collect_oi_for_bucket(pe_near_strikes, "PE")

    # Print OI summary
    print("\n" + "=" * 80)
    print(f"📊 {index} OI SUMMARY (Expiry: {options[0].expiry_code})")
    print("=" * 80)
    print(f"Spot: {spot:.2f}   ATM strike: {atm}")
    print(f"Total CE OI (all strikes): {int(total_oi_ce):,}")
    print(f"Total PE OI (all strikes): {int(total_oi_pe):,}")
    print(f"CE/PE OI Ratio: {(total_oi_ce / total_oi_pe) if total_oi_pe > 0 else 0:.2f}")

    print("\nNear-ATM OI (4 ITM + ATM + 4 OTM on each side):")
    print(f"  CE Near-ATM OI: {int(ce_near_oi):,}")
    print(f"  PE Near-ATM OI: {int(pe_near_oi):,}")
    
    # Near-ATM OI Comparison Table
    print("\n" + "=" * 80)
    print("📈 NEAR-ATM OI COMPARISON")
    print("=" * 80)
    print("Total OI of Near-ATM Call and Put Near-ATM Strikes")
    print(f"{'Call':<12} {'Put':<12} {'Difference'}")
    print("-" * 50)
    
    total_current = ce_near_oi + pe_near_oi
    if total_current > 0:
        if ce_near_oi > pe_near_oi:
            ce_pe_diff_pct = ((ce_near_oi - pe_near_oi) / total_current) * 100.0
            if ce_pe_diff_pct >= NEAR_ATM_OI_DIFF_THRESHOLD_PERCENT:
                diff_display = f"CE is more than {ce_pe_diff_pct:.1f}%"
            else:
                diff_display = f"{ce_pe_diff_pct:.1f}%"
        elif pe_near_oi > ce_near_oi:
            ce_pe_diff_pct = ((pe_near_oi - ce_near_oi) / total_current) * 100.0
            if ce_pe_diff_pct >= NEAR_ATM_OI_DIFF_THRESHOLD_PERCENT:
                diff_display = f"PE is more than {ce_pe_diff_pct:.1f}%"
            else:
                diff_display = f"{ce_pe_diff_pct:.1f}%"
        else:
            ce_pe_diff_pct = 0.0
            diff_display = "0.0%"
    else:
        ce_pe_diff_pct = 0.0
        diff_display = "No data"
    
    print(f"{int(ce_near_oi):<12,} {int(pe_near_oi):<12,} {diff_display}")
    print("new")
    
    if ce_pe_diff_pct >= NEAR_ATM_OI_DIFF_THRESHOLD_PERCENT:
        print(f"\n⚠️  ALERT: Near-ATM OI difference ({ce_pe_diff_pct:.1f}%) exceeds {NEAR_ATM_OI_DIFF_THRESHOLD_PERCENT}% threshold!")
        if pe_near_oi > ce_near_oi:
            print(f"    PE Near-ATM OI ({int(pe_near_oi):,}) is {ce_pe_diff_pct:.1f}% more than CE Near-ATM OI ({int(ce_near_oi):,})")
        else:
            print(f"    CE Near-ATM OI ({int(ce_near_oi):,}) is {ce_pe_diff_pct:.1f}% more than PE Near-ATM OI ({int(pe_near_oi):,})")

    # Detail table for near-ATM strikes
    print("\nDetailed Near-ATM Strikes:")
    print(f"{'Type':<4} {'Strike':>8} {'OI':>12} {'LTP':>12} {'High':>12} {'Low':>12}")
    print("-" * 60)

    def print_rows(strike_list: List[int], opt_type: str):
        for s in strike_list:
            token = strike_type_to_token.get((s, opt_type))
            if not token:
                continue
            q = safe_get_quote(token)
            oi = safe_get_num(q, "oi", "openInterest", "open_interest")
            ltp = safe_get_num(q, "ltp", "iv", "c")
            high = safe_get_num(q, "h", "highPrice", "high")
            low = safe_get_num(q, "lo", "lowPrice", "low")
            print(f"{opt_type:<4} {s:>8} {int(oi):>12,} {ltp:>12.2f} {high:>12.2f} {low:>12.2f}")

    print_rows(sorted(ce_near_strikes), "CE")
    print_rows(sorted(pe_near_strikes), "PE")

    if stale_warnings:
        print("\n⚠️  OI is stale for some near-ATM strikes (last update >5 min):")
        for msg in sorted(set(stale_warnings)):
            print(f"   - {msg}")

    # Critical warning: any critical token with missing OI
    critical_missing = [
        t for t in critical_tokens
        if safe_get_num(quotes.get(t, {}), "oi", "openInterest", "open_interest") == 0.0
    ]
    if critical_missing:
        print(f"\n🔴 CRITICAL: {len(critical_missing)} ITM/ATM strikes missing OI (within 500 pts of spot).")


    # Expensiveness check (calculate before updating sheets)
    comp = decide_comparison_strikes(spot, lower, atm, upper)
    expensiveness_data = None
    
    if comp:
        strike_ce, type_ce, strike_pe, type_pe, mode = comp
        token_ce = strike_type_to_token.get((strike_ce, type_ce))
        token_pe = strike_type_to_token.get((strike_pe, type_pe))
        
        if token_ce and token_pe:
            q_ce = safe_get_quote(token_ce)
            q_pe = safe_get_quote(token_pe)
            price_ce = safe_get_num(q_ce, "ltp", "iv", "c")
            price_pe = safe_get_num(q_pe, "ltp", "iv", "c")

            if price_ce > 0 and price_pe > 0:
                diff = abs(price_ce - price_pe)
                avg = (price_ce + price_pe) / 2.0
                diff_pct = diff / avg * 100.0 if avg != 0 else 0.0

                if price_ce > price_pe:
                    expensive_side = "CE"
                    expensive_strike = strike_ce
                elif price_pe > price_ce:
                    expensive_side = "PE"
                    expensive_strike = strike_pe
                else:
                    expensive_side = "NONE"
                    expensive_strike = None

                expensiveness_data = {
                    "side": expensive_side,
                    "strike": expensive_strike,
                    "diff_pts": diff,
                    "diff_pct": diff_pct,
                    "mode": mode,
                    "spot": spot,
                    "ce_strike": strike_ce,
                    "pe_strike": strike_pe,
                    "ce_price": price_ce,
                    "pe_price": price_pe
                }

    # Logging calculation completion for terminal transparency
    print("📊 Calculation complete. Results displayed above.")

    # Print expensiveness check results to terminal
    if not comp:
        print("\n⚪ No CE/PE expensiveness check performed (spot not at strike or near midpoint).")
        return {
            "index_summary": {
                "index": index,
                "expiry": options[0].expiry_code,
                "spot": spot,
                "total_ce_oi": total_oi_ce,
                "total_pe_oi": total_oi_pe,
                "near_atm_ce_oi": ce_near_oi,
                "near_atm_pe_oi": pe_near_oi,
                "atm_strike": atm,
            },
            "expensiveness": None
        }

    strike_ce, type_ce, strike_pe, type_pe, mode = comp
    token_ce = strike_type_to_token.get((strike_ce, type_ce))
    token_pe = strike_type_to_token.get((strike_pe, type_pe))
    if not token_ce or not token_pe:
        print("\n⚠️  Comparison strikes not available in scrip master.")
        return

    q_ce = safe_get_quote(token_ce)
    q_pe = safe_get_quote(token_pe)
    price_ce = safe_get_num(q_ce, "ltp", "iv", "c")
    price_pe = safe_get_num(q_pe, "ltp", "iv", "c")

    if price_ce <= 0 or price_pe <= 0:
        print("\n⚠️  CE/PE prices missing or zero; cannot decide expensiveness.")
        return

    diff = abs(price_ce - price_pe)
    avg = (price_ce + price_pe) / 2.0
    diff_pct = diff / avg * 100.0 if avg != 0 else 0.0

    if price_ce > price_pe:
        expensive_side = "CE"
        expensive_strike = strike_ce
    elif price_pe > price_ce:
        expensive_side = "PE"
        expensive_strike = strike_pe
    else:
        expensive_side = "NONE"
        expensive_strike = None

    print("\n" + "=" * 80)
    print(f"💰 CE vs PE EXPENSIVENESS CHECK ({mode} case)")
    print("=" * 80)
    if mode == "ATM":
        print(f"Spot {spot:.2f} is at strike {atm}. Comparing:")
        print(f"  CE {atm} vs PE {atm}")
    elif mode == "NEAR_ATM":
        print(f"Spot {spot:.2f} is near strike {strike_ce} (within ±{MIDPOINT_TOLERANCE_POINTS} pts). Comparing:")
        print(f"  CE {strike_ce} vs PE {strike_pe}")
    else:
        # MIDDLE (deprecated, kept for backward compatibility)
        print(
            f"Spot {spot:.2f} is near the middle between {lower} and {upper} "
            f"(tolerance ±{MIDPOINT_TOLERANCE_POINTS} pts)."
        )
        print(f"Comparing: CE {strike_ce} (higher strike) vs PE {strike_pe} (lower strike)")

    print(f"\n  CE {strike_ce} LTP: {price_ce:.2f}")
    print(f"  PE {strike_pe} LTP: {price_pe:.2f}")
    print(f"  Difference: {diff:.2f} points  ({diff_pct:.2f}%)")

    if expensive_side == "NONE":
        print("\n🟡 Both sides are roughly equal; no clear expensive side.")
    else:
        print(
            f"\n🟢 {expensive_side} is expensive at strike {expensive_strike} "
            f"by {diff:.2f} points ({diff_pct:.2f}%) compared to the other side."
        )
    
    # Return all calculated data for use by callers (Redis/API)
    return {
        "index_summary": {
            "index": index,
            "expiry": options[0].expiry_code,
            "spot": spot,
            "total_ce_oi": total_oi_ce,
            "total_pe_oi": total_oi_pe,
            "near_atm_ce_oi": ce_near_oi,
            "near_atm_pe_oi": pe_near_oi,
            "atm_strike": atm,
        },
        "expensiveness": expensiveness_data
    }
    

# ---------------------------------------------------------------------------
# Lightweight API server (optional) for mobile/remote consumption
# ---------------------------------------------------------------------------


def start_api_server(api_host: str, api_port: int, shared_state: Dict):
    """
    Start a FastAPI server in a background thread to expose live state.

    shared_state expected keys:
      - "index": str
      - "expiry": str
      - "index_spot": dict reference with key "value"
      - "near_atm_history": list reference
      - "snapshot": dict reference (latest OI summary)
    """
    if not HAS_FASTAPI:
        print("⚠️  FastAPI/uvicorn not installed. Skipping API server. Install with: pip install fastapi uvicorn")
        return None

    app = FastAPI(title="Nifty/Sensex OI Analyzer API", version="1.0")

    @app.get("/health")
    def health():
        return {"status": "ok", "index": shared_state.get("index"), "expiry": shared_state.get("expiry")}

    @app.get("/state")
    def state():
        snapshot = shared_state.get("snapshot") or {}
        index_spot_value = shared_state.get("index_spot", {}).get("value")
        
        # If spot is None from WebSocket, try to get it from snapshot (last known value)
        if index_spot_value is None and snapshot.get("spot"):
            index_spot_value = snapshot.get("spot")
        
        # Log for debugging
        import datetime
        now = datetime.now_ist().strftime("%H:%M:%S")
        print(f"[{now}] API /state called - Spot: {index_spot_value}, Snapshot keys: {list(snapshot.keys())}")
        
        return {
            "index": shared_state.get("index"),
            "expiry": shared_state.get("expiry"),
            "spot": index_spot_value,
            "near_atm": snapshot,
        }

    @app.get("/history")
    def history(limit: int = 200):
        hist = shared_state.get("near_atm_history") or []
        if limit and limit > 0:
            hist = hist[-limit:]
        return {"count": len(hist), "items": hist}

    def run():
        uvicorn.run(app, host=api_host, port=api_port, log_level="info")

    thread = threading.Thread(target=run, daemon=True)
    thread.start()
    print(f"🌐 API server running at http://{api_host}:{api_port} (endpoints: /health, /state, /history)")
    return thread


# ---------------------------------------------------------------------------
# Main runner
# ---------------------------------------------------------------------------


def analyze_once(index: str, session: KotakSession, redis_storer: Optional[RedisStorer] = None) -> None:
    """Single snapshot analysis (non-continuous mode)."""
    options, expiry = load_options_for_index(index)
    idx_quote = session.get_index_quote(index)
    if not idx_quote or not idx_quote.get("ltp"):
        print("❌ Could not fetch index spot; aborting.")
        return
    spot = float(idx_quote.get("ltp") or 0.0)

    exchange_segment = "nse_fo" if index.upper() == "NIFTY" else "bse_fo"
    tokens = [opt.token for opt in options]
    print(f"\n📡 Fetching quotes for {len(tokens)} {index} options (expiry {expiry})...")

    # API/WebSocket allows max 100 scrips per request, so batch and merge
    max_batch = 100
    quotes: Dict[str, Dict] = {}
    for i in range(0, len(tokens), max_batch):
        batch = tokens[i : i + max_batch]
        batch_num = (i // max_batch) + 1
        total_batches = (len(tokens) + max_batch - 1) // max_batch
        print(f"  📦 Batch {batch_num}/{total_batches}: requesting {len(batch)} tokens...")
        batch_quotes = session.get_option_quotes(batch, exchange_segment=exchange_segment)
        if batch_quotes:
            quotes.update(batch_quotes)
            print(f"    ✓ Batch {batch_num} received {len(batch_quotes)} quotes")
        else:
            print(f"    ⚠️  Batch {batch_num} returned no quotes")

    if not quotes:
        print("❌ No quotes received across all batches; check auth/base URL.")
        return

    results = compute_oi_summary_and_expensiveness(index, options, spot, quotes)
    
    # Push to Redis if enabled
    if redis_storer is not None and redis_storer.enabled:
        # Pushing summary (snapshot)
        index_summary = results["index_summary"]
        current_date = now_ist().strftime("%Y-%m-%d")
        snapshot = {
            "date": current_date,
            "timestamp": now_ist().strftime("%H:%M:%S"),
            **index_summary,
            "ratio": (index_summary["total_pe_oi"] / index_summary["total_ce_oi"]) if index_summary["total_ce_oi"] > 0 else 0.0,
            # Index OHLC + change (for NIFTY/SENSEX dashboards)
            "open": float(idx_quote.get("open") or 0.0),
            "high": float(idx_quote.get("high") or 0.0),
            "low": float(idx_quote.get("low") or 0.0),
            "close": float(idx_quote.get("close") or 0.0),
            "change": float(idx_quote.get("change") or 0.0),
            "per_change": float(idx_quote.get("per_change") or 0.0),
        }
        redis_storer.push_snapshot(index, snapshot)
        
        # Pushing expensiveness
        if results["expensiveness"]:
            redis_storer.push_expensiveness(index, results["expensiveness"])
        
        # Build mapping for full chain storage
        strike_type_to_token = {(opt.strike, opt.option_type): opt.token for opt in options}
        chain_data = {
            "quotes": quotes,
            "strike_type_to_token": strike_type_to_token
        }
        redis_storer.push_full_chain(index, chain_data)


def analyze_continuous(
    index: str,
    session: KotakSession,
    oi_interval: int = 60,
    price_check_interval: int = 3,
    start_api: bool = False,
    api_host: str = "0.0.0.0",
    api_port: int = 8000,
    redis_storer: Optional[RedisStorer] = None,
) -> None:
    """
    Continuous analysis mode with permanent WebSocket connections.
    
    - Opens persistent WebSocket connections for all option tokens
    - Updates prices (LTP, high, low) continuously
    - Calculates OI totals every oi_interval seconds (default 60s) with carry-forward
    - Checks expensive/cheap side every price_check_interval seconds (default 3s)
    """
    import threading
    
    options, expiry = load_options_for_index(index)
    exchange_segment = "nse_fo" if index.upper() == "NIFTY" else "bse_fo"
    tokens = [opt.token for opt in options]
    
    # Shared state dictionary - updated continuously by WebSocket callbacks
    # Format: {token: {"ltp": float, "high": float, "low": float, "oi": float, "oi_update_time": timestamp}}
    shared_quotes: Dict[str, Dict] = {}
    
    # Track index spot (updated continuously via persistent WebSocket)
    index_spot: Dict[str, float] = {"value": None}
    index_ws_conn = None
    
    print(f"\n📡 Setting up permanent WebSocket connections for {len(tokens)} {index} options...")
    
    # Open persistent WebSocket connections in batches (max 100 per connection)
    max_batch = 100
    ws_connections: List = []
    batch_quotes_dicts: List[Dict] = []
    
    for i in range(0, len(tokens), max_batch):
        batch = tokens[i : i + max_batch]
        if not batch:
            continue
        
        batch_num = (i // max_batch) + 1
        total_batches = (len(tokens) + max_batch - 1) // max_batch
        print(f"  📦 Opening WebSocket batch {batch_num}/{total_batches} ({len(batch)} tokens)...")
        
        # Add delay between batches to avoid overwhelming the server
        if batch_num > 1:
            delay = 2.0  # 2 second delay between batches
            print(f"    ⏳ Waiting {delay}s before connecting batch {batch_num}...")
            time.sleep(delay)
        
        # Use embedded persistent WebSocket
        try:
            result = session.get_option_quotes_persistent(batch, exchange_segment=exchange_segment)
        except Exception as e:
            print(f"    ❌ Batch {batch_num} exception: {e}")
            result = None
        
        if result and isinstance(result, tuple):
            ws_conn, quotes_dict = result
            if ws_conn and quotes_dict is not None:
                ws_connections.append(ws_conn)
                batch_quotes_dicts.append(quotes_dict)
                print(f"    ✓ Batch {batch_num} WebSocket connected and subscribed")
            else:
                print(f"    ⚠️  Batch {batch_num} WebSocket connection failed (ws_conn or quotes_dict is None)")
        else:
            print(f"    ⚠️  Batch {batch_num} WebSocket returned invalid result (result={type(result).__name__})")
    
    if not ws_connections:
        print("❌ No WebSocket connections established. Aborting.")
        return
    
    print(f"\n✅ Established {len(ws_connections)} permanent WebSocket connections")
    print(f"   Data will update continuously. OI calculated every {oi_interval}s, price checks every {price_check_interval}s.\n")
    
    # Set up persistent index spot WebSocket
    index_result = session.get_index_spot_persistent(index)
    if index_result and isinstance(index_result, tuple):
        index_ws_conn, index_spot_state = index_result
        if index_spot_state:
            index_spot = index_spot_state
    else:
        print("⚠️  Could not start persistent index WebSocket; spot may be None.")
    
    # Wait briefly for initial data
    print("⏳ Waiting for initial data to arrive...")
    time.sleep(5)
        
    # Merge all batch quotes into shared state
    def merge_quotes_to_shared():
        """Merge quotes from all batches into shared_quotes with OI carry-forward logic."""
        for batch_dict in batch_quotes_dicts:
            for token, quote_data in batch_dict.items():
                if not token or not isinstance(quote_data, dict):
                    continue
                
                if token not in shared_quotes:
                    shared_quotes[token] = {
                        "ltp": 0.0,
                        "high": 0.0,
                        "low": 0.0,
                        "oi": 0.0,
                        "oi_update_time": None,
                        "last_quote": {}
                    }
                
                # Update prices immediately (these come continuously from WebSocket)
                ltp_val = session._safe_get(quote_data, "ltp", "iv", "c", default="N/A")
                high_val = session._safe_get(quote_data, "h", "highPrice", "high", default="N/A")
                low_val = session._safe_get(quote_data, "lo", "lowPrice", "low", default="N/A")
                oi_val = session._safe_get(quote_data, "oi", "openInterest", "open_interest", default="N/A")
                
                # Update LTP, high, low (always update these live)
                try:
                    if ltp_val != "N/A":
                        ltp_float = float(ltp_val)
                        if ltp_float > 0:
                            shared_quotes[token]["ltp"] = ltp_float
                except (ValueError, TypeError):
                    pass
                
                try:
                    if high_val != "N/A":
                        high_float = float(high_val)
                        if high_float > 0:
                            shared_quotes[token]["high"] = high_float
                except (ValueError, TypeError):
                    pass
                
                try:
                    if low_val != "N/A":
                        low_float = float(low_val)
                        if low_float > 0:
                            shared_quotes[token]["low"] = low_float
                except (ValueError, TypeError):
                    pass
                
                # Update OI only if we receive a valid new value, otherwise carry forward previous OI
                try:
                    if oi_val != "N/A":
                        oi_float = float(oi_val)
                        # Only update if we get a valid positive OI value
                        if oi_float >= 0:  # Allow 0 as valid
                            shared_quotes[token]["oi"] = oi_float
                            shared_quotes[token]["oi_update_time"] = time.time()
                        # If oi_float is negative or invalid, keep previous OI (carry-forward)
                except (ValueError, TypeError):
                    # Invalid OI value - keep previous OI (carry-forward)
                    pass
                
                # Store last quote for reference
                shared_quotes[token]["last_quote"] = quote_data
    
    # Continuous update loop
    last_oi_calc = time.time()
    last_price_check = time.time()
    last_alert_time = 0.0  # Track last alert time to avoid spam
    alert_cooldown = 30.0  # Minimum seconds between alerts (30 seconds)
    stop_flag = threading.Event()
    
    # Connection health monitoring
    last_data_update = time.time()  # Track when we last received data
    connection_health_check_interval = 60.0  # Check connection health every 60 seconds
    last_health_check = time.time()
    data_stale_threshold = 120.0  # Consider data stale if no updates for 2 minutes
    
    # Track history of all Near-ATM OI calculations for comparison
    near_atm_oi_history: List[Dict] = []  # List of {"ce": float, "pe": float, "timestamp": str, "diff_pct": float, "diff_display": str}

    # Snapshot for API exposure
    api_snapshot: Dict[str, Dict] = {}

    # Shared state for optional API server
    shared_api_state = {
        "index": index,
        "expiry": expiry,
        "index_spot": index_spot,
        "near_atm_history": near_atm_oi_history,
        "snapshot": api_snapshot,
    }

    api_thread = None
    if start_api:
        api_thread = start_api_server(api_host, api_port, shared_api_state)
    
    print("\n" + "=" * 80)
    print("🔄 CONTINUOUS ANALYSIS MODE - WebSocket connections active (REDIS STORAGE ENABLED)")
    print("=" * 80)
    print(f"Press Ctrl+C to stop\n")
    
    try:
        while not stop_flag.is_set():
            # Merge latest quotes from all batches
            merge_quotes_to_shared()
            
            current_time = time.time()
            spot = index_spot.get("value")
            
            # Connection health check: Detect if data has gone stale
            if current_time - last_health_check >= connection_health_check_interval:
                last_health_check = current_time
                
                # Check if we're receiving data updates
                time_since_update = current_time - last_data_update
                if time_since_update > data_stale_threshold:
                    timestamp = now_ist().strftime("%H:%M:%S")
                    print(f"\n[{timestamp}] ⚠️  WARNING: No data updates for {time_since_update:.0f} seconds!")
                    print(f"[{timestamp}]    WebSocket connections may have dropped.")
                    
                    # Force reconnection if data is stale for more than 5 minutes
                    max_stale_time = 300.0  # 5 minutes
                    if time_since_update > max_stale_time:
                        print(f"[{timestamp}]    🔄 Data stale for {time_since_update:.0f}s (>{max_stale_time:.0f}s)")
                        print(f"[{timestamp}]    Forcing reconnection...")
                        # Exit the function to trigger auto-reconnect wrapper
                        return
                    else:
                        print(f"[{timestamp}]    Will reconnect if stale for >{max_stale_time:.0f}s")
                
                # Check if we have any data at all
                total_quotes = sum(len(batch_dict) for batch_dict in batch_quotes_dicts)
                if total_quotes == 0:
                    timestamp = now_ist().strftime("%H:%M:%S")
                    print(f"\n[{timestamp}] ⚠️  WARNING: No quotes data available!")
                    print(f"[{timestamp}]    All WebSocket connections may have failed.")
                    print(f"[{timestamp}]    🔄 Forcing reconnection...")
                    # Exit the function to trigger auto-reconnect wrapper
                    return
            
            # Fast loop: Check expensive/cheap side every price_check_interval seconds
            if current_time - last_price_check >= price_check_interval:
                last_price_check = current_time
                
                if spot:
                    # Quick expensive/cheap check using live prices
                    strikes = sorted({opt.strike for opt in options})
                    atm, lower, upper = find_atm_and_neighbors(strikes, spot)
                    comp = decide_comparison_strikes(spot, lower, atm, upper)
                    
                    if comp:
                        strike_ce, type_ce, strike_pe, type_pe, mode = comp
                        strike_type_to_token = {(opt.strike, opt.option_type): opt.token for opt in options}
                        token_ce = strike_type_to_token.get((strike_ce, type_ce))
                        token_pe = strike_type_to_token.get((strike_pe, type_pe))
                        
                        if token_ce and token_pe:
                            q_ce = shared_quotes.get(token_ce, {})
                            q_pe = shared_quotes.get(token_pe, {})
                            
                            price_ce = q_ce.get("ltp", 0.0)
                            price_pe = q_pe.get("ltp", 0.0)
                            
                            if price_ce > 0 and price_pe > 0:
                                diff = abs(price_ce - price_pe)
                                avg = (price_ce + price_pe) / 2.0
                                diff_pct = diff / avg * 100.0 if avg != 0 else 0.0
                                
                                expensive_side = "CE" if price_ce > price_pe else ("PE" if price_pe > price_ce else "NONE")
                                
                                timestamp = now_ist().strftime("%H:%M:%S")
                                print(f"\n[{timestamp}] 💰 {mode} Case | Spot: {spot:.2f} | "
                                      f"CE {strike_ce}: {price_ce:.2f} | PE {strike_pe}: {price_pe:.2f} | "
                                      f"{expensive_side} expensive by {diff:.2f} pts ({diff_pct:.2f}%)")
                                
                                # Push expensiveness to Redis
                                if redis_storer is not None and redis_storer.enabled:
                                    redis_storer.push_expensiveness(index, {
                                        "timestamp": timestamp,
                                        "side": expensive_side,
                                        "diff_pts": diff,
                                        "diff_pct": diff_pct,
                                        "mode": mode,
                                        "spot": spot,
                                        "ce_strike": strike_ce,
                                        "pe_strike": strike_pe,
                                        "ce_price": price_ce,
                                        "pe_price": price_pe
                                    })
            
            # Slow loop: Calculate OI totals every oi_interval seconds
            if current_time - last_oi_calc >= oi_interval:
                last_oi_calc = current_time
                
                if spot:
                    # Build quotes dict for OI calculation (using stored OI with carry-forward)
                    quotes_for_oi = {}
                    for opt in options:
                        token_data = shared_quotes.get(opt.token, {})
                        quotes_for_oi[opt.token] = {
                            "ltp": token_data.get("ltp", 0.0),
                            "h": token_data.get("high", 0.0),
                            "lo": token_data.get("low", 0.0),
                            "oi": token_data.get("oi", 0.0),  # Uses last updated OI (carry-forward)
                            "openInterest": token_data.get("oi", 0.0),
                            "open_interest": token_data.get("oi", 0.0),
                            "oi_timestamp": token_data.get("oi_update_time"),
                        }
                    
                    # Calculate and display OI summary
                    timestamp = now_ist().strftime("%H:%M:%S")
                    print(f"\n[{timestamp}] " + "=" * 76)
                    print(f"[{timestamp}] 📊 {index} OI SUMMARY (Expiry: {expiry})")
                    
                    # Total OI
                    total_oi_ce = sum(
                        quotes_for_oi.get(opt.token, {}).get("oi", 0.0)
                        for opt in options if opt.option_type == "CE"
                    )
                    total_oi_pe = sum(
                        quotes_for_oi.get(opt.token, {}).get("oi", 0.0)
                        for opt in options if opt.option_type == "PE"
                    )
                    
                    print(f"[{timestamp}] Spot: {spot:.2f} | Total CE OI: {int(total_oi_ce):,} | "
                          f"Total PE OI: {int(total_oi_pe):,} | PCR: {(total_oi_pe / total_oi_ce) if total_oi_ce > 0 else 0:.2f}")
                    
                    # Near-ATM OI
                    strikes = sorted({opt.strike for opt in options})
                    near = select_near_atm_strikes(strikes, spot)
                    strike_type_to_token = {(opt.strike, opt.option_type): opt.token for opt in options}
                    
                    ce_near_strikes = sorted(set(near["ATM"] + near["CE_ITM"] + near["CE_OTM"]))
                    pe_near_strikes = sorted(set(near["ATM"] + near["PE_ITM"] + near["PE_OTM"]))
                    
                    ce_near_oi = sum(
                        quotes_for_oi.get(strike_type_to_token.get((s, "CE"), ""), {}).get("oi", 0.0)
                        for s in ce_near_strikes
                        if strike_type_to_token.get((s, "CE"))
                    )
                    pe_near_oi = sum(
                        quotes_for_oi.get(strike_type_to_token.get((s, "PE"), ""), {}).get("oi", 0.0)
                        for s in pe_near_strikes
                        if strike_type_to_token.get((s, "PE"))
                    )
                    
                    print(f"[{timestamp}] Near-ATM OI | CE: {int(ce_near_oi):,} | PE: {int(pe_near_oi):,}")
                    
                    # Compare with previous Near-ATM OI values
                    print(f"\n[{timestamp}] 📈 NEAR-ATM OI COMPARISON")
                    print(f"[{timestamp}] Total OI of Near-ATM Call and Put Near-ATM Strikes")
                    print(f"[{timestamp}] {'Call':<12} {'Put':<12} {'Difference'}")
                    print(f"[{timestamp}] {'-' * 50}")
                    
                    # Calculate percentage difference between CE and PE for current calculation
                    total_current = ce_near_oi + pe_near_oi
                    if total_current > 0:
                        if ce_near_oi > pe_near_oi:
                            ce_pe_diff_pct = ((ce_near_oi - pe_near_oi) / total_current) * 100.0
                            if ce_pe_diff_pct >= NEAR_ATM_OI_DIFF_THRESHOLD_PERCENT:
                                diff_display = f"CE is more than {ce_pe_diff_pct:.1f}%"
                            else:
                                diff_display = f"{ce_pe_diff_pct:.1f}%"
                        elif pe_near_oi > ce_near_oi:
                            ce_pe_diff_pct = ((pe_near_oi - ce_near_oi) / total_current) * 100.0
                            if ce_pe_diff_pct >= NEAR_ATM_OI_DIFF_THRESHOLD_PERCENT:
                                diff_display = f"PE is more than {ce_pe_diff_pct:.1f}%"
                            else:
                                diff_display = f"{ce_pe_diff_pct:.1f}%"
                        else:
                            ce_pe_diff_pct = 0.0
                            diff_display = "0.0%"
                    else:
                        ce_pe_diff_pct = 0.0
                        diff_display = "No data"
                    
                    # Display all previous calculations from history
                    for hist_item in near_atm_oi_history:
                        print(f"[{hist_item['timestamp']}] {int(hist_item['ce']):<12,} {int(hist_item['pe']):<12,} {hist_item['diff_display']}")
                    
                    # Decide whether to add a new entry (skip if unchanged from last)
                    is_duplicate = False
                    if near_atm_oi_history:
                        last = near_atm_oi_history[-1]
                        if (
                            int(last["ce"]) == int(ce_near_oi)
                            and int(last["pe"]) == int(pe_near_oi)
                            and last["diff_display"] == diff_display
                        ):
                            is_duplicate = True
                    
                    # Display current calculation
                    print(f"[{timestamp}] {int(ce_near_oi):<12,} {int(pe_near_oi):<12,} {diff_display}")
                    if is_duplicate:
                        print(f"[{timestamp}] unchanged (not saved)")
                    else:
                        print(f"[{timestamp}] new")
                    
                    # Alert if difference exceeds threshold
                    if ce_pe_diff_pct >= NEAR_ATM_OI_DIFF_THRESHOLD_PERCENT:
                        print(f"\n[{timestamp}] ⚠️  ALERT: Near-ATM OI difference ({ce_pe_diff_pct:.1f}%) exceeds {NEAR_ATM_OI_DIFF_THRESHOLD_PERCENT}% threshold!")
                        if pe_near_oi > ce_near_oi:
                            print(f"[{timestamp}]    PE Near-ATM OI ({int(pe_near_oi):,}) is {ce_pe_diff_pct:.1f}% more than CE Near-ATM OI ({int(ce_near_oi):,})")
                        else:
                            print(f"[{timestamp}]    CE Near-ATM OI ({int(ce_near_oi):,}) is {ce_pe_diff_pct:.1f}% more than PE Near-ATM OI ({int(pe_near_oi):,})")
                    
                    # Update API snapshot - use clear() and update to ensure fresh data
                    api_snapshot.clear()
                    api_snapshot.update({
                        "timestamp": timestamp,
                        "index": index,
                        "expiry": expiry,
                        "spot": spot,
                        # Index OHLC + change from index WebSocket (best-effort; may be None early on)
                        "open": index_spot.get("open") or 0.0,
                        "high": index_spot.get("high") or 0.0,
                        "low": index_spot.get("low") or 0.0,
                        "close": index_spot.get("close") or 0.0,
                        "change": index_spot.get("change") or 0.0,
                        "per_change": index_spot.get("per_change") or 0.0,
                        "ce_near_oi": ce_near_oi,
                        "pe_near_oi": pe_near_oi,
                        "ce_pe_diff_pct": ce_pe_diff_pct,
                        "diff_display": diff_display,
                        "total_oi_ce": total_oi_ce,
                        "total_oi_pe": total_oi_pe,
                        "ratio": (total_oi_pe / total_oi_ce) if total_oi_ce > 0 else 0.0,  # Fixed: PCR should be Put/Call ratio
                    })

                    # Add current calculation to history unless it’s a duplicate
                    if not is_duplicate:
                        near_atm_oi_history.append({
                            "ce": ce_near_oi,
                            "pe": pe_near_oi,
                            "timestamp": timestamp,
                            "diff_pct": ce_pe_diff_pct,
                            "diff_display": diff_display
                        })
                    
                    # Push snapshot and full chain to Redis
                    if redis_storer is not None and redis_storer.enabled:
                        exp_pl = build_expensiveness_redis_payload(
                            spot, strikes, strike_type_to_token, quotes_for_oi, timestamp
                        )
                        redis_storer.push_expensiveness(index, exp_pl)

                        redis_storer.push_snapshot(index, api_snapshot)
                        
                        # Store full quotes in Redis hash (matched by strike price)
                        chain_data = {
                            "quotes": dict(shared_quotes),
                            "strike_type_to_token": strike_type_to_token
                        }
                        redis_storer.push_full_chain(index, chain_data)
                    
                    # Debug: show coverage and OI for near-ATM strikes when zeros appear
                    if ce_near_oi == 0 or pe_near_oi == 0:
                        # Also dump one sample raw quote for inspection
                        sample_token = None
                        if ce_near_strikes:
                            sample_token = strike_type_to_token.get((ce_near_strikes[0], "CE"))
                        if not sample_token and pe_near_strikes:
                            sample_token = strike_type_to_token.get((pe_near_strikes[0], "PE"))
                        if sample_token:
                            sample_quote = shared_quotes.get(sample_token, {}).get("last_quote") or {}
                            print(f"[debug] Sample quote for token {sample_token}: {sample_quote}")
                        
                        def dump_near_bucket(strike_list, opt_type):
                            rows = []
                            missing = []
                            for s in strike_list:
                                token = strike_type_to_token.get((s, opt_type))
                                if not token:
                                    missing.append((s, "<no token>"))
                                    continue
                                q = quotes_for_oi.get(token, {})
                                rows.append((s, token, q.get("oi", 0.0)))
                            return rows, missing
                        
                        ce_rows, ce_missing = dump_near_bucket(ce_near_strikes, "CE")
                        pe_rows, pe_missing = dump_near_bucket(pe_near_strikes, "PE")
                        
                        print("[debug] Near-ATM CE strikes:")
                        for s, t, oi in ce_rows:
                            print(f"  CE {s} | token {t} | oi {oi}")
                        if ce_missing:
                            print(f"  Missing CE tokens for strikes: {[m[0] for m in ce_missing]}")
                        
                        print("[debug] Near-ATM PE strikes:")
                        for s, t, oi in pe_rows:
                            print(f"  PE {s} | token {t} | oi {oi}")
                        if pe_missing:
                            print(f"  Missing PE tokens for strikes: {[m[0] for m in pe_missing]}")
                    
                    # Check alert conditions and play sound if all conditions met
                    if (current_time - last_alert_time) >= alert_cooldown:
                        alert_ready, pe_low_details = check_alert_conditions(
                            index, options, spot, shared_quotes, strike_type_to_token
                        )
                        if alert_ready:
                            timestamp = now_ist().strftime("%H:%M:%S")
                            print(f"\n[{timestamp}] 🚨🚨🚨 ALERT TRIGGERED! 🚨🚨🚨")
                            print(f"[{timestamp}] Conditions met:")
                            print(f"  ✓ Total CE OI ({int(total_oi_ce):,}) > Total PE OI ({int(total_oi_pe):,})")
                            print(f"  ✓ Near-ATM CE OI ({int(ce_near_oi):,}) > Near-ATM PE OI ({int(pe_near_oi):,})")
                            print(f"  ✓ Call side is expensive at ATM strike")
                            print(f"  ✓ PE strikes (3 OTM + 1 ITM) are within {PE_PRICE_THRESHOLD_PERCENT}% of their low")
                            if pe_low_details:
                                print("  ↳ PE strike check details:")
                                for strike, ltp, low, pct in pe_low_details:
                                    print(f"     - {strike} PE  |  LTP {ltp:.2f}  |  Low {low:.2f}  |  Diff {pct:.2f}%")
                            play_alert_sound()
                            print(f"[{timestamp}] 🔊 Alert sound played!\n")
                            last_alert_time = current_time
            
            # Small sleep to avoid CPU spinning
            time.sleep(0.5)
    
    except KeyboardInterrupt:
        print("\n\n🛑 Stopping continuous analysis...")
        stop_flag.set()
        
        # Close all WebSocket connections
        for ws_conn in ws_connections:
            try:
                ws_conn.close()
            except:
                pass
        if index_ws_conn:
            try:
                index_ws_conn.close()
            except:
                pass
        
        print("✅ WebSocket connections closed. Exiting.")
    
    except Exception as e:
        print(f"❌ Error in continuous analysis: {e}")
        import traceback
        traceback.print_exc()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Analyze NIFTY/SENSEX options OI and CE/PE expensiveness using Kotak Neo."
    )
    parser.add_argument(
        "--index",
        "-i",
        choices=["NIFTY", "SENSEX"],
        default="NIFTY",
        help="Index to analyze (default: NIFTY)",
    )
    parser.add_argument(
        "--continuous",
        "-c",
        action="store_true",
        help="Run in continuous mode with permanent WebSocket connections. "
             "Prices update live, OI calculated every --oi-interval seconds, "
             "expensive/cheap checks every --price-check-interval seconds.",
    )
    parser.add_argument(
        "--oi-interval",
        type=int,
        default=60,
        help="Interval in seconds for OI calculations in continuous mode (default: 60).",
    )
    parser.add_argument(
        "--price-check-interval",
        type=int,
        default=3,
        help="Interval in seconds for expensive/cheap price checks in continuous mode (default: 3).",
    )
    parser.add_argument(
        "--api",
        action="store_true",
        help="Start a lightweight FastAPI server to expose live data (/health, /state, /history).",
    )
    parser.add_argument(
        "--api-host",
        default="0.0.0.0",
        help="API server host (default: 0.0.0.0).",
    )
    parser.add_argument(
        "--api-port",
        type=int,
        default=8000,
        help="API server port (default: 8000).",
    )
    parser.add_argument(
        "--loop",
        action="store_true",
        help="[DEPRECATED] Run in old loop mode (re-run snapshot analysis every interval seconds). "
             "Use --continuous instead for permanent WebSocket connections.",
    )
    parser.add_argument(
        "--interval",
        type=int,
        default=60,
        help="[DEPRECATED] Interval in seconds for old loop mode. Use --oi-interval instead.",
    )
    # Redis Arguments
    parser.add_argument(
        "--redis",
        action="store_true",
        help="Enable storing live data in Redis.",
    )
    parser.add_argument(
        "--redis-host",
        default="localhost",
        help="Redis host (default: localhost).",
    )
    parser.add_argument(
        "--redis-port",
        type=int,
        default=6379,
        help="Redis port (default: 6379).",
    )
    parser.add_argument(
        "--redis-db",
        type=int,
        default=0,
        help="Redis database index (default: 0).",
    )

    args = parser.parse_args()

    # Resolve credentials path flexibly (project root -> script dir -> cwd)
    cred_candidates = [
        os.path.join(PROJECT_ROOT, "b.txt"),
        os.path.join(SCRIPT_DIR, "b.txt"),
        os.path.join(os.getcwd(), "b.txt"),
    ]
    credentials_path = None
    for c in cred_candidates:
        if os.path.exists(c):
            credentials_path = c
            break
    if not credentials_path:
        # Fall back to project root even if missing (session will print a clear error)
        credentials_path = os.path.join(PROJECT_ROOT, "b.txt")

    # Initialize Redis Storer
    redis_storer = RedisStorer(
        enabled=args.redis,
        host=args.redis_host,
        port=args.redis_port,
        db=args.redis_db
    )

    session = KotakSession(credentials_path=credentials_path)
    if not session.authenticate():
        sys.exit(1)

    if args.continuous:
        # New continuous mode with permanent WebSocket connections and auto-reconnect
        print(f"\n🔄 Starting continuous mode with auto-reconnect...")
        print(f"   Will automatically reconnect if WebSocket connections drop.\n")
        
        reconnect_count = 0
        max_reconnects = 100  # Prevent infinite loops
        reconnect_delay = 30  # Wait 30 seconds between reconnects
        
        while reconnect_count < max_reconnects:
            try:
                if reconnect_count > 0:
                    print(f"\n🔄 Reconnecting (attempt {reconnect_count + 1}/{max_reconnects})...")
                    print(f"   Waiting {reconnect_delay} seconds before reconnect...")
                    time.sleep(reconnect_delay)
                    
                    # Re-authenticate before reconnecting
                    print("🔐 Re-authenticating...")
                    if not session.authenticate():
                        print("❌ Re-authentication failed. Will retry...")
                        reconnect_count += 1
                        continue
                
                # Run continuous analysis
                analyze_continuous(
                    args.index,
                    session,
                    oi_interval=args.oi_interval,
                    price_check_interval=args.price_check_interval,
                    start_api=args.api,
                    api_host=args.api_host,
                    api_port=args.api_port,
                    redis_storer=redis_storer,
                )
                
                # If analyze_continuous returns normally, it means it exited cleanly
                print("\n⚠️  Continuous mode exited. Reconnecting...")
                reconnect_count += 1
                
            except KeyboardInterrupt:
                print("\n🛑 Stopped by user.")
                break
            except Exception as e:
                print(f"\n❌ Error in continuous mode: {e}")
                print(f"   Will attempt to reconnect...")
                reconnect_count += 1
        
        if reconnect_count >= max_reconnects:
            print(f"\n❌ Max reconnection attempts ({max_reconnects}) reached. Exiting.")
            sys.exit(1)
    elif args.loop:
        # Old loop mode (deprecated but still supported)
        print(f"\n⚠️  WARNING: --loop mode is deprecated. Use --continuous for better performance.\n")
        print(f"🔁 Loop mode: analyzing {args.index} every {args.interval} seconds. Ctrl+C to stop.\n")
        try:
            while True:
                analyze_once(args.index, session, redis_storer=redis_storer)
                print("\n" + "-" * 80)
                print(f"Sleeping {args.interval} seconds before next run...")
                time.sleep(args.interval)
        except KeyboardInterrupt:
            print("\n🛑 Stopped by user.")
    else:
        # Single snapshot mode
        analyze_once(args.index, session, redis_storer=redis_storer)


if __name__ == "__main__":
    main()


