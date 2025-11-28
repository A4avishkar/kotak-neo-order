#!/usr/bin/env python3
"""
Fetch Nifty Live Data - Standalone Version (No SDK Required)
Uses direct REST API calls and WebSocket connection with embedded binary protocol
All binary protocol functions are embedded - no SDK dependencies
"""

import json
import time
import ssl
import datetime
import requests
import websocket
import threading
import pyotp
import urllib3
import csv
import os
from urllib.parse import urlencode, quote

# Suppress SSL warnings
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ============================================================================
# EMBEDDED BINARY PROTOCOL FUNCTIONS (from HSWebSocketLib)
# ============================================================================

# Constants
MAX_SCRIPS = 100
topic_list = {}  # Global topic list for WebSocket data
ws = None  # Global WebSocket connection for acknowledgements

FieldTypes = {
    'FLOAT32': 1,
    'LONG': 2,
    'DATE': 3,
    'STRING': 4
}
TRASH_VAL = -2147483648

STRING_INDEX = {
    'NAME': 51,
    'SYMBOL': 52,
    'EXCHG': 53,
    'TSYMBOL': 54
}

DEPTH_INDEX = {
    "MULTIPLIER": 32,
    "PRECISION": 33
}

BinRespTypes = {
    "CONNECTION_TYPE": 1,
    "THROTTLING_TYPE": 2,
    "ACK_TYPE": 3,
    "SUBSCRIBE_TYPE": 4,
    "UNSUBSCRIBE_TYPE": 5,
    "DATA_TYPE": 6,
    "CHPAUSE_TYPE": 7,
    "CHRESUME_TYPE": 8,
    "SNAPSHOT": 9,
    "OPC_SUBSCRIBE": 10
}

BinRespStat = {
    "OK": "K",
    "NOT_OK": "N"
}

ResponseTypes = {
    "SNAP": 83,
    "UPDATE": 85
}

STAT = {
    "OK": "Ok",
    "NOT_OK": "NotOk"
}

RespTypeValues = {
    "CONN": "cn",
    "SUBS": "sub",
    "UNSUBS": "unsub",
    "SNAP": "snap",
    "CHANNELR": "cr",
    "CHANNELP": "cp",
    "OPC": "opc"
}

RespCodes = {
    'SUCCESS': 200,
    'CONNECTION_FAILED': 11001,
    'CONNECTION_INVALID': 11002,
    'SUBSCRIPTION_FAILED': 11011,
    'UNSUBSCRIPTION_FAILED': 11012,
    'SNAPSHOT_FAILED': 11013,
    'CHANNELP_FAILED': 11031,
    'CHANNELR_FAILED': 11032
}

TopicTypes = {
    "SCRIP": "sf",
    "INDEX": "if",
    "DEPTH": "dp"
}

INDEX_INDEX = {
    "LTP": 2,
    "CLOSE": 3,
    "CHANGE": 10,
    "PERCHANGE": 11,
    "MULTIPLIER": 8,
    "PRECISION": 9
}

SCRIP_INDEX = {
    "VOLUME": 4,
    "LTP": 5,
    "CLOSE": 21,
    "VWAP": 13,
    "MULTIPLIER": 23,
    "PRECISION": 24,
    "CHANGE": 25,
    "PERCHANGE": 26,
    "TURNOVER": 27
}

SCRIP_PREFIX = "sf"
INDEX_PREFIX = "if"
DEPTH_PREFIX = "dp"

# Data type helper
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

# Depth mapping
DEPTH_MAPPING = [None] * 55
DEPTH_MAPPING[0] = DataType("ftm0", FieldTypes.get("DATE"))
DEPTH_MAPPING[1] = DataType("dtm1", FieldTypes.get("DATE"))
DEPTH_MAPPING[2] = DataType("bp", FieldTypes.get("FLOAT32"))
DEPTH_MAPPING[3] = DataType("bp1", FieldTypes.get("FLOAT32"))
DEPTH_MAPPING[4] = DataType("bp2", FieldTypes.get("FLOAT32"))
DEPTH_MAPPING[5] = DataType("bp3", FieldTypes.get("FLOAT32"))
DEPTH_MAPPING[6] = DataType("bp4", FieldTypes.get("FLOAT32"))
DEPTH_MAPPING[7] = DataType("sp", FieldTypes.get("FLOAT32"))
DEPTH_MAPPING[8] = DataType("sp1", FieldTypes.get("FLOAT32"))
DEPTH_MAPPING[9] = DataType("sp2", FieldTypes.get("FLOAT32"))
DEPTH_MAPPING[10] = DataType("sp3", FieldTypes.get("FLOAT32"))
DEPTH_MAPPING[11] = DataType("sp4", FieldTypes.get("FLOAT32"))
DEPTH_MAPPING[12] = DataType("bq", FieldTypes.get("LONG"))
DEPTH_MAPPING[13] = DataType("bq1", FieldTypes.get("LONG"))
DEPTH_MAPPING[14] = DataType("bq2", FieldTypes.get("LONG"))
DEPTH_MAPPING[15] = DataType("bq3", FieldTypes.get("LONG"))
DEPTH_MAPPING[16] = DataType("bq4", FieldTypes.get("LONG"))
DEPTH_MAPPING[17] = DataType("bs", FieldTypes.get("LONG"))
DEPTH_MAPPING[18] = DataType("bs1", FieldTypes.get("LONG"))
DEPTH_MAPPING[19] = DataType("bs2", FieldTypes.get("LONG"))
DEPTH_MAPPING[20] = DataType("bs3", FieldTypes.get("LONG"))
DEPTH_MAPPING[21] = DataType("bs4", FieldTypes.get("LONG"))
DEPTH_MAPPING[22] = DataType("bno1", FieldTypes.get("LONG"))
DEPTH_MAPPING[23] = DataType("bno2", FieldTypes.get("LONG"))
DEPTH_MAPPING[24] = DataType("bno3", FieldTypes.get("LONG"))
DEPTH_MAPPING[25] = DataType("bno4", FieldTypes.get("LONG"))
DEPTH_MAPPING[26] = DataType("bno5", FieldTypes.get("LONG"))
DEPTH_MAPPING[27] = DataType("sno1", FieldTypes.get("LONG"))
DEPTH_MAPPING[28] = DataType("sno2", FieldTypes.get("LONG"))
DEPTH_MAPPING[29] = DataType("sno3", FieldTypes.get("LONG"))
DEPTH_MAPPING[30] = DataType("sno4", FieldTypes.get("LONG"))
DEPTH_MAPPING[31] = DataType("sno5", FieldTypes.get("LONG"))
DEPTH_MAPPING[DEPTH_INDEX["MULTIPLIER"]] = DataType("mul", FieldTypes["LONG"])
DEPTH_MAPPING[DEPTH_INDEX["PRECISION"]] = DataType("prec", FieldTypes["LONG"])
DEPTH_MAPPING[STRING_INDEX["NAME"]] = DataType("name", FieldTypes["STRING"])
DEPTH_MAPPING[STRING_INDEX["SYMBOL"]] = DataType("tk", FieldTypes["STRING"])
DEPTH_MAPPING[STRING_INDEX["EXCHG"]] = DataType("e", FieldTypes["STRING"])
DEPTH_MAPPING[STRING_INDEX["TSYMBOL"]] = DataType("ts", FieldTypes["STRING"])

# Helper functions
def leadingZero(a):
    return "0" + str(a) if a < 10 else str(a)

def getFormatDate(a):
    date = datetime.datetime.fromtimestamp(a)
    formatDate = "{}/{}/{} {}:{}:{}".format(
        leadingZero(date.day),
        leadingZero(date.month),
        date.year,
        leadingZero(date.hour),
        leadingZero(date.minute),
        leadingZero(date.second)
    )
    return formatDate

# ByteData class for binary message construction
class ByteData:
    def __init__(self, c):
        self.pos = 0
        self.bytes = [0] * (c)
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
        str_len = len(d)
        for i in range(str_len):
            self.bytes[self.pos] = ord(d[i])
            self.pos += 1

    def appendByteArr(self, e, d):
        for i in range(d):
            self.bytes[self.pos] = e[i]
            self.pos += 1

# TopicData base class
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

# DepthTopicData class
class DepthTopicData(TopicData):
    def __init__(self):
        super().__init__(TopicTypes["DEPTH"])
        self.updatedFieldsArray = [None] * 100
        self.multiplier = None
        self.precision = None
        self.precisionValue = None

    def setMultiplierAndPrec(self):
        if self.updatedFieldsArray[DEPTH_INDEX['PRECISION']]:
            self.precision = self.fieldDataArray[DEPTH_INDEX['PRECISION']]
            self.precisionValue = 10 ** self.precision
        if self.updatedFieldsArray[DEPTH_INDEX['MULTIPLIER']]:
            self.multiplier = self.fieldDataArray[DEPTH_INDEX['MULTIPLIER']]

    def prepareData(self, type=None):
        self.prepareCommonData()
        json_res = {}
        for d in range(len(DEPTH_MAPPING)):
            c = DEPTH_MAPPING[d]
            e = self.fieldDataArray[d]
            if self.updatedFieldsArray[d] and e is not None and c:
                if c["type"] == FieldTypes.get("FLOAT32"):
                    e = round(e / (self.multiplier * self.precisionValue), self.precision)
                elif c["type"] == FieldTypes.get("DATE"):
                    e = getFormatDate(e)
                json_res[c["name"]] = str(e)
        self.updatedFieldsArray = [None] * 100
        if type is not None:
            json_res["request_type"] = type
        return json_res

# ScripTopicData class
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
        if self.updatedFieldsArray[SCRIP_INDEX["VOLUME"]] or self.updatedFieldsArray[SCRIP_INDEX["VWAP"]]:
            volume = self.fieldDataArray[SCRIP_INDEX["VOLUME"]]
            vwap = self.fieldDataArray[SCRIP_INDEX["VWAP"]]
            if volume is not None and vwap is not None:
                self.fieldDataArray[SCRIP_INDEX["TURNOVER"]] = volume * vwap
                self.updatedFieldsArray[SCRIP_INDEX["TURNOVER"]] = True
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

# IndexTopicData class
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

# Helper functions for binary protocol
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
    """Convert bytes to string (pure Python, no numpy)"""
    return bytes(a).decode('utf-8', errors='ignore')

def send_json_arr_resp(a):
    """Wrap response in JSON array"""
    json_arr_res = []
    json_arr_res.append(a)
    return json.dumps(json_arr_res)

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

# HSWrapper class for parsing binary WebSocket messages
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
        elif feed_type == TopicTypes.get("DEPTH"):
            topic = DepthTopicData()
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
                            print("Invalid topic feed type !")
                    else:
                        if c == ResponseTypes.get("UPDATE"):
                            f = buf2long(e[pos: pos + 4])
                            pos += 4
                            d = topic_list.get(f)
                            if not d:
                                print("Topic Not Available in TopicList!")
                            else:
                                fcount = buf2long(e[pos:pos + 1])
                                pos += 1
                                for index in range(fcount):
                                    fvalue = buf2long(e[pos:pos + 4])
                                    d.setLongValues(index, fvalue)
                                    pos += 4
                            if d:
                                h.append(d.prepareData("SUB"))
                        else:
                            print("Invalid ResponseType: " + str(c))
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

# ============================================================================
# MAIN CLASS - NiftyLiveStandalone
# ============================================================================

class NiftyLiveStandalone:
    def __init__(self):
        self.consumer_key = None
        self.consumer_secret = None
        self.mobile_number = None
        self.totp_secret = None
        self.mpin = None
        self.ucc = None
        
        # Session tokens
        self.bearer_token = None
        self.view_token = None
        self.view_sid = None
        self.edit_token = None
        self.edit_sid = None
        self.server_id = None
        self.base_url = None
        
        # WebSocket
        self.ws = None
        self.ws_connected = False
        self.nifty_data = None
        
    def load_credentials(self, file_path="b.txt"):
        """Load credentials from b.txt file"""
        credentials = {}
        try:
            with open(file_path, 'r') as f:
                for line in f:
                    line = line.strip()
                    if '=' in line and not line.startswith('#'):
                        key, value = line.split('=', 1)
                        key = key.strip()
                        value = value.strip()
                        
                        # Remove quotes if present
                        if value.startswith('"') and value.endswith('"'):
                            value = value[1:-1]
                        elif value.startswith("'") and value.endswith("'"):
                            value = value[1:-1]
                        
                        credentials[key] = value
            
            self.consumer_key = credentials.get('KOTAK_CONSUMER_KEY')
            self.consumer_secret = credentials.get('KOTAK_CONSUMER_SECRET') or ''
            self.mobile_number = credentials.get('KOTAK_MOBILE_NUMBER')
            self.totp_secret = credentials.get('KOTAK_TOTP_SECRET')
            self.mpin = credentials.get('KOTAK_MPIN')
            self.ucc = credentials.get('KOTAK_UCC')
            
            return True
        except Exception as e:
            print(f"Error loading credentials: {e}")
            return False
    
    def get_base_url(self):
        """Get base URL from UCC"""
        url = "https://lapi.kotaksecurities.com/algo-user/v5/get-base-url"
        params = {'id': self.ucc}
        response = requests.get(url, params=params)
        if response.status_code == 200:
            self.base_url = response.json().get('data').get('baseURL') + '/'
            print(f"✓ Base URL: {self.base_url}")
            return True
        else:
            print(f"❌ Failed to get base URL: {response.text}")
            return False
    
    def totp_login(self):
        """Login using TOTP - Direct API"""
        # Generate TOTP
        totp = pyotp.TOTP(self.totp_secret)
        totp_code = totp.now()
        
        # Format mobile number
        formatted_mobile = self.mobile_number
        if not self.mobile_number.startswith('+'):
            if len(self.mobile_number) == 10 and self.mobile_number.isdigit():
                formatted_mobile = '+91' + self.mobile_number
        
        # Use direct TOTP login endpoint
        url = "https://mis.kotaksecurities.com/login/1.0/tradeApiLogin"
        
        headers = {
            'Content-Type': 'application/json',
            'Authorization': self.consumer_key,
            'neo-fin-key': 'neotradeapi'
        }
        body = {
            'mobileNumber': formatted_mobile,
            'ucc': self.ucc,
            'totp': totp_code
        }
        
        response = requests.post(url, headers=headers, json=body, verify=False)
        if response.status_code == 200:
            data = response.json().get('data', {})
            if data.get('status') != 'success':
                error_msg = response.json().get('error') or response.json().get('message') or 'Unknown error'
                print(f"❌ TOTP login failed: {error_msg}")
                return False
            
            self.view_token = data.get('token')
            self.view_sid = data.get('sid')
            self.server_id = data.get('hsServerId') or ''
            print("✓ TOTP login successful")
            return True
        else:
            print(f"❌ TOTP login failed: {response.status_code} - {response.text}")
            return False
    
    def totp_validate(self):
        """Validate TOTP with MPIN to get edit token"""
        url = "https://mis.kotaksecurities.com/login/1.0/tradeApiValidate"
        
        headers = {
            'Content-Type': 'application/json',
            'Authorization': self.consumer_key,
            'sid': self.view_sid,
            'Auth': self.view_token,
            'neo-fin-key': 'neotradeapi'
        }
        body = {
            'mpin': self.mpin
        }
        
        response = requests.post(url, headers=headers, json=body, verify=False)
        if response.status_code == 200:
            data = response.json().get('data', {})
            if data.get('status') != 'success':
                error_msg = response.json().get('error') or response.json().get('message') or 'Unknown error'
                print(f"❌ TOTP validate failed: {error_msg}")
                return False
            
            self.edit_token = data.get('token')
            self.edit_sid = data.get('sid') or self.view_sid
            print("✓ TOTP validation successful")
            print(f"  Edit Token: {self.edit_token[:20]}...")
            print(f"  Edit SID: {self.edit_sid}")
            return True
        else:
            print(f"❌ TOTP validate failed: {response.status_code} - {response.text}")
            return False
    
    def session_init_for_bearer_token(self):
        """Initialize session to get bearer_token for quotes API"""
        import base64
        
        if 'gw-napi' in (self.base_url or ''):
            session_base_url = "https://napi.kotaksecurities.com/"
        else:
            session_base_url = "https://mnapi.kotaksecurities.com/"
        
        url = f"{session_base_url}oauth2/token"
        
        if not self.consumer_secret:
            print("⚠️  No consumer_secret - skipping session_init (will use edit_token for quotes)")
            return True
        
        credentials = f"{self.consumer_key}:{self.consumer_secret}"
        base64_credentials = base64.b64encode(credentials.encode('ascii')).decode('ascii')
        
        headers = {
            'Content-Type': 'application/json',
            'Authorization': f'Basic {base64_credentials}'
        }
        
        body = {
            "grant_type": "client_credentials"
        }
        
        try:
            response = requests.post(url, headers=headers, json=body, verify=False)
            if response.status_code == 200:
                data = response.json()
                self.bearer_token = data.get('access_token')
                print("✓ Session init successful (bearer_token obtained)")
                return True
            else:
                print(f"⚠️  Session init failed: {response.status_code} - Will try using edit_token")
                return True
        except Exception as e:
            print(f"⚠️  Session init error: {e} - Will try using edit_token")
            return True
    
    def authenticate(self):
        """Complete authentication flow"""
        print("\n🔐 Starting Authentication...")
        
        if not self.load_credentials():
            return False
        
        if not self.get_base_url():
            print("⚠️  Warning: Could not get base URL, but continuing...")
        
        self.session_init_for_bearer_token()
        
        if not self.totp_login():
            return False
        
        if not self.totp_validate():
            return False
        
        print("✅ Authentication complete!\n")
        return True
    
    def get_nifty_via_websocket(self):
        """Get Nifty data via WebSocket using edit_token (binary protocol)"""
        global topic_list, ws
        print("\n📡 Connecting to WebSocket for Nifty 50 data...")
        
        ws_url = "wss://mlhsm.kotaksecurities.com"
        hs_wrapper = HSWrapper()
        topic_list = {}  # Reset topic list
        
        reconnect_attempt = 0
        stop_event = threading.Event()
        manual_stop = False
        
        def build_ws_app(state):
            nonlocal stop_event
            nifty_data = {"value": None}
            connection_ok = {"value": False}
            subscription_ok = {"value": False}
            first_data_received = {"value": False}
            data_updates = {"value": 0}
            connection_lost_event = state["connection_lost_event"]
            
            def on_open(ws_app):
                global ws
                state["ws_connection"] = ws_app
                ws = ws_app
                print("  ✓ WebSocket connected")
                conn_bytes = prepareConnectionRequest2(self.edit_token, self.edit_sid)
                ws_app.send(conn_bytes, opcode=0x2)
                print("  ✓ Connection message sent (binary)")
            
            def on_message(ws_app, message):
                try:
                    if not isinstance(message, bytes):
                        return
                    
                    parsed = hs_wrapper.parseData(message)
                    
                    if parsed:
                        if isinstance(parsed, str):
                            try:
                                parsed = json.loads(parsed)
                            except Exception:
                                pass
                        
                        if isinstance(parsed, list) and parsed:
                            item = parsed[0]
                            if isinstance(item, dict):
                                if item.get('type') == 'cn' and item.get('stat') == 'Ok':
                                    connection_ok["value"] = True
                                    print("  ✓ Connection acknowledged")
                                    time.sleep(0.5)
                                    scrips = "nse_cm|Nifty 50"
                                    sub_bytes = prepareSubsUnSubsRequest(
                                        scrips,
                                        BinRespTypes["SUBSCRIBE_TYPE"],
                                        INDEX_PREFIX,
                                        2
                                    )
                                    if sub_bytes:
                                        ws_app.send(sub_bytes, opcode=0x2)
                                        print("  ✓ Subscription message sent for Nifty 50")
                                    else:
                                        print("  ⚠️  Failed to prepare subscription message")
                                
                                elif item.get('type') in ['sub', 'ifs']:
                                    subscription_ok["value"] = True
                                    print("  ✓ Subscription acknowledged")
                        
                        if isinstance(parsed, list):
                            for item in parsed:
                                if isinstance(item, dict):
                                    if 'iv' in item or 'ic' in item or 'highPrice' in item or 'tk' in item:
                                        token_val = item.get('tk')
                                        if token_val == 'Nifty 50' or not token_val:
                                            nifty_data["value"] = {
                                                'token': token_val or 'Nifty 50',
                                                'ltp': item.get('iv'),
                                                'change': item.get('cng'),
                                                'change_pct': item.get('nc'),
                                                'high': item.get('highPrice'),
                                                'low': item.get('lowPrice'),
                                                'open': item.get('openingPrice'),
                                                'close': item.get('ic'),
                                                'exchange': item.get('e') or 'nse_cm',
                                                'timestamp': item.get('tvalue')
                                            }
                                            
                                            data_updates["value"] += 1
                                            request_type = item.get('request_type', 'UPDATE')
                                            
                                            os.system('cls' if os.name == 'nt' else 'clear')
                                            
                                            is_live_update = request_type in ['SUB', 'UPDATE']
                                            market_status = "🟢 LIVE" if is_live_update else "🟡 SNAPSHOT (Market may be closed)"
                                            
                                            print("\n" + "="*60)
                                            print("📊 NIFTY 50 LIVE DATA (WebSocket)")
                                            print("="*60)
                                            print(f"Status: {market_status} | Updates received: {data_updates['value']} | Type: {request_type}")
                                            
                                            if not is_live_update:
                                                print("ℹ️  Note: Snapshot data shows last traded values. Live updates occur when market is open.")
                                            
                                            print("-"*60)
                                            self.nifty_data = nifty_data["value"]
                                            self.display_nifty_data()
                                            print("\nPress Ctrl+C to stop...")
                                            
                                            if not first_data_received["value"]:
                                                first_data_received["value"] = True
                except Exception as e:
                    print(f"  ⚠️  Error parsing WebSocket message: {e}")
                    import traceback
                    traceback.print_exc()
            
            def on_error(ws_app, error):
                print(f"  ⚠️  WebSocket error: {error}")
                connection_lost_event.set()
            
            def on_close(ws_app, close_status_code, close_msg):
                if not connection_lost_event.is_set():
                    print("\n  ⚠️  WebSocket closed")
                connection_lost_event.set()
            
            state["handlers"] = {
                "on_open": on_open,
                "on_message": on_message,
                "on_error": on_error,
                "on_close": on_close,
                "nifty_data": nifty_data,
                "connection_ok": connection_ok,
                "subscription_ok": subscription_ok,
                "first_data_received": first_data_received,
                "data_updates": data_updates
            }
            
            return websocket.WebSocketApp(
                ws_url,
                on_open=on_open,
                on_message=on_message,
                on_error=on_error,
                on_close=on_close
            )
        
        while not stop_event.is_set():
            state = {
                "ws_connection": None,
                "connection_lost_event": threading.Event(),
                "handlers": {}
            }
            
            ws_connection = build_ws_app(state)
            state["ws_connection"] = ws_connection
            first_data_received = state["handlers"]["first_data_received"]
            connection_ok = state["handlers"]["connection_ok"]
            subscription_ok = state["handlers"]["subscription_ok"]
            connection_lost_event = state["connection_lost_event"]
            
            ws_thread = threading.Thread(
                target=lambda: ws_connection.run_forever(
                    sslopt={"cert_reqs": ssl.CERT_NONE},
                    ping_interval=45,
                    ping_timeout=20
                ),
                daemon=True
            )
            ws_thread.start()
            
            print("  ⏳ Waiting for initial data...")
            timeout = 30
            start_time = time.time()
            while not stop_event.is_set() and not connection_lost_event.is_set() and not first_data_received["value"] and (time.time() - start_time) < timeout:
                time.sleep(0.5)
            
            if not first_data_received["value"]:
                if stop_event.is_set():
                    break
                if connection_lost_event.is_set():
                    print("  ⚠️  Connection ended before data arrived")
                elif not connection_ok["value"]:
                    print("  ⚠️  Connection not acknowledged")
                elif not subscription_ok["value"]:
                    print("  ⚠️  Subscription not acknowledged")
                else:
                    print("  ⚠️  No data received within timeout")
                
                try:
                    ws_connection.close()
                except Exception:
                    pass
                
                reconnect_attempt += 1
                backoff = min(30, 3 * reconnect_attempt)
                print(f"🔁 Retrying connection in {backoff} seconds...")
                time.sleep(backoff)
                continue
            
            if first_data_received["value"]:
                reconnect_attempt = 0
                print("\n✅ Live data stream active! WebSocket will stay open and update automatically.")
                print("   Data updates will appear every few seconds...\n")
            
            try:
                while not stop_event.is_set():
                    time.sleep(1)
                    if connection_lost_event.is_set():
                        print("\n⚠️  WebSocket connection lost.")
                        break
            except KeyboardInterrupt:
                manual_stop = True
                stop_event.set()
                print("\n\n🛑 Stopping live data stream...")
            finally:
                try:
                    ws_connection.close()
                    print("  ✓ WebSocket closed")
                except Exception:
                    pass
            
            if stop_event.is_set():
                break
            
            reconnect_attempt += 1
            backoff = min(30, 3 * reconnect_attempt)
            print(f"🔁 Attempting to reconnect (attempt {reconnect_attempt}) in {backoff} seconds...")
            time.sleep(backoff)
        
        return bool(first_data_received["value"]) and not connection_lost_event.is_set() if not manual_stop else True
    
    def get_nifty_via_rest(self):
        """Get Nifty data via REST API"""
        neo_symbol = "nse_cm|Nifty 50"
        quote_type = "all"
        
        from urllib.parse import quote as url_quote
        encoded_symbol = url_quote(neo_symbol)
        
        if self.base_url and 'gw-napi' in self.base_url:
            url_path = f"apim/quotes/1.0/quotes/neosymbol/{encoded_symbol}/{quote_type}"
        else:
            url_path = f"apim/quotes/2.0/quotes/neosymbol/{encoded_symbol}/{quote_type}"
        
        url = f"{self.base_url}{url_path}"
        
        auth_token = self.bearer_token if self.bearer_token else self.edit_token
        
        headers = {
            'Authorization': f'Bearer {auth_token}',
            'Content-Type': 'application/json'
        }
        
        print(f"  📡 Calling: {url}")
        print(f"  🔑 Using token: {auth_token[:30]}...")
        
        try:
            response = requests.get(url, headers=headers)
            if response.status_code == 200:
                data = response.json()
                quotes = data.get('data', {}).get('quotes', [])
                
                if quotes:
                    quote_data = quotes[0]
                    self.nifty_data = {
                        'token': quote_data.get('tk'),
                        'ltp': quote_data.get('iv'),
                        'change': quote_data.get('cng'),
                        'change_pct': quote_data.get('nc'),
                        'high': quote_data.get('highPrice'),
                        'low': quote_data.get('lowPrice'),
                        'open': quote_data.get('openingPrice'),
                        'close': quote_data.get('ic'),
                        'volume': quote_data.get('v'),
                        'turnover': quote_data.get('to'),
                        'exchange': quote_data.get('e'),
                        'timestamp': quote_data.get('tvalue')
                    }
                    self.display_nifty_data()
                    return True
                else:
                    print(f"⚠️  No quotes data in response")
                    print(f"   Response: {json.dumps(data, indent=2)}")
            else:
                print(f"❌ REST API failed: {response.status_code}")
                print(f"   Response: {response.text}")
        except Exception as e:
            print(f"❌ Error fetching via REST: {e}")
            import traceback
            traceback.print_exc()
        
        return False
    
    def display_nifty_data(self):
        """Display Nifty data"""
        if not self.nifty_data:
            return
        
        print("\n" + "="*60)
        print("📊 NIFTY 50 LIVE DATA")
        print("="*60)
        print(f"Token:        {self.nifty_data.get('token', 'N/A')}")
        print(f"LTP:          ₹{self.nifty_data.get('ltp', 'N/A')}")
        print(f"Change:       ₹{self.nifty_data.get('change', 'N/A')} ({self.nifty_data.get('change_pct', 'N/A')}%)")
        print(f"Open:         ₹{self.nifty_data.get('open', 'N/A')}")
        print(f"High:         ₹{self.nifty_data.get('high', 'N/A')}")
        print(f"Low:          ₹{self.nifty_data.get('low', 'N/A')}")
        print(f"Close:        ₹{self.nifty_data.get('close', 'N/A')}")
        print(f"Volume:       {self.nifty_data.get('volume', 'N/A')}")
        print(f"Turnover:     ₹{self.nifty_data.get('turnover', 'N/A')}")
        print(f"Exchange:     {self.nifty_data.get('exchange', 'N/A')}")
        print(f"Timestamp:    {self.nifty_data.get('timestamp', 'N/A')}")
        print("="*60 + "\n")
    
    def fetch_nifty_live(self):
        """Main method to fetch Nifty live data"""
        print("="*60)
        print("🚀 NIFTY LIVE DATA FETCHER (Standalone - No SDK)")
        print("="*60)
        
        if not self.authenticate():
            print("❌ Authentication failed")
            return
        
        print("📡 Fetching Nifty 50 data via WebSocket...")
        if self.get_nifty_via_websocket():
            print("✅ Successfully fetched Nifty data!")
        else:
            print("⚠️  WebSocket method failed, trying REST API...")
            if self.get_nifty_via_rest():
                print("✅ Successfully fetched Nifty data via REST!")
            else:
                print("❌ Failed to fetch Nifty data")
    
    def fetch_nifty_continuous(self, interval=10):
        """Fetch Nifty data continuously"""
        print("="*60)
        print("🚀 NIFTY LIVE DATA FETCHER - CONTINUOUS MODE")
        print("="*60)
        
        if not self.authenticate():
            print("❌ Authentication failed")
            return
        
        print(f"📡 Fetching Nifty 50 data every {interval} seconds...")
        print("Press Ctrl+C to stop\n")
        
        try:
            while True:
                if self.get_nifty_via_rest():
                    print(f"⏱️  Next update in {interval} seconds... ({time.strftime('%H:%M:%S')})\n")
                else:
                    print("⚠️  Failed to fetch, retrying in 5 seconds...\n")
                    time.sleep(5)
                    continue
                
                time.sleep(interval)
        except KeyboardInterrupt:
            print("\n\n🛑 Stopped fetching data")


def main():
    import argparse
    
    parser = argparse.ArgumentParser(description='Fetch Nifty live data - Standalone (No SDK)')
    parser.add_argument('--continuous', '-c', action='store_true', 
                       help='Fetch data continuously')
    parser.add_argument('--interval', '-i', type=int, default=10,
                       help='Interval between fetches in seconds (default: 10)')
    
    args = parser.parse_args()
    
    fetcher = NiftyLiveStandalone()
    
    if args.continuous:
        fetcher.fetch_nifty_continuous(interval=args.interval)
    else:
        fetcher.fetch_nifty_live()


if __name__ == "__main__":
    main()

