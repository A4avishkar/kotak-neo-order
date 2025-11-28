#!/usr/bin/env python3
"""
Fetch Live Data for All Sensex Option Strikes (No SDK Version)
Reads option tokens from sensexcurrentexpirypsymbol.py output CSV
and fetches live market data for each strike price

This version uses direct REST API calls and embedded WebSocket binary protocol (no SDK required).
"""

import os
import sys
import csv
import glob
import json
import time
import ssl
import requests
import websocket
import threading
import urllib3
import pyotp
import base64
from urllib.parse import quote as url_quote
import pandas as pd
from datetime import datetime

# Suppress SSL warnings
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ============================================================================
# EMBEDDED BINARY PROTOCOL FUNCTIONS (from HSWebSocketLib - no SDK required)
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

# Helper functions
def leadingZero(a):
    return "0" + str(a) if a < 10 else str(a)

def getFormatDate(a):
    date = datetime.fromtimestamp(a)
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

# Index mapping
def DataType(c, d):
    return {"name": c, "type": d}

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


class AllStrikesDataFetcher:
    def __init__(self):
        self.consumer_key = None
        self.consumer_secret = None
        self.mobile_number = None
        self.totp_secret = None
        self.mpin = None
        self.ucc = None
        
        # Session tokens
        self.view_token = None
        self.view_sid = None
        self.edit_token = None
        self.edit_sid = None
        self.server_id = None
        self.base_url = None
        self.bearer_token = None  # For REST quotes API
        
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
            print(f"❌ Error loading credentials: {e}")
            return False
    
    def get_base_url(self):
        """Get base URL from UCC (optional for quotes; WebSocket doesn't need it)."""
        try:
            url = "https://lapi.kotaksecurities.com/algo-user/v5/get-base-url"
            params = {'id': self.ucc}
            response = requests.get(url, params=params)
            if response.status_code == 200:
                self.base_url = response.json().get('data', {}).get('baseURL', '')
                if self.base_url:
                    self.base_url += '/'
                print(f"✓ Base URL: {self.base_url}")
                return True
        except Exception:
            pass
        print("⚠️  Failed to get base URL (continuing; not required for WebSocket)")
        return False
    
    def totp_login(self):
        """Login using TOTP - Direct REST API (no SDK)"""
        totp_code = pyotp.TOTP(self.totp_secret).now()
        mobile = self.mobile_number
        if isinstance(mobile, str) and not mobile.startswith('+') and len(mobile) == 10 and mobile.isdigit():
            mobile = '+91' + mobile
        
        url = "https://mis.kotaksecurities.com/login/1.0/tradeApiLogin"
        headers = {
            'Content-Type': 'application/json',
            'Authorization': self.consumer_key,
            'neo-fin-key': 'neotradeapi'
        }
        body = {
            'mobileNumber': mobile,
            'ucc': self.ucc,
            'totp': totp_code
        }
        
        try:
            response = requests.post(url, headers=headers, json=body, verify=False)
            if response.status_code == 200:
                data = response.json().get('data', {})
                if data.get('status') != 'success':
                    error_msg = response.json().get('error') or response.json().get('message') or 'Unknown error'
                    print(f"❌ TOTP login failed: {error_msg}")
                    return False
                
                self.view_token = data.get('token')
                self.view_sid = data.get('sid')
                self.server_id = data.get('hsServerId')
                print("✓ TOTP login successful")
                return True
            else:
                print(f"❌ TOTP login failed: {response.status_code} - {response.text}")
                return False
        except Exception as e:
            print(f"❌ TOTP login error: {e}")
            return False
    
    def totp_validate(self):
        """Validate TOTP with MPIN - Direct REST API (no SDK)"""
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
        
        try:
            response = requests.post(url, headers=headers, json=body, verify=False)
            if response.status_code == 200:
                data = response.json().get('data', {})
                if data.get('status') != 'success':
                    error_msg = response.json().get('error') or response.json().get('message') or 'Unknown error'
                    print(f"❌ TOTP validate failed: {error_msg}")
                    return False
                
                self.edit_token = data.get('token')
                self.edit_sid = data.get('sid') or self.view_sid
                self.server_id = data.get('hsServerId') or self.server_id
                base_url = data.get('baseUrl')
                if base_url:
                    self.base_url = base_url + '/' if not base_url.endswith('/') else base_url
                
                print("✓ TOTP validation successful")
                return True
            else:
                print(f"❌ TOTP validate failed: {response.status_code} - {response.text}")
                return False
        except Exception as e:
            print(f"❌ TOTP validate error: {e}")
            return False
    
    def session_init_for_bearer_token(self):
        """Initialize session to get bearer_token for REST quotes API"""
        # For quotes API, we need bearer_token from OAuth2 session_init
        if not self.consumer_secret:
            print("⚠️  No consumer_secret - skipping session_init (will use edit_token for quotes)")
            return True  # Continue anyway
        
        # Use session base URL
        if self.base_url and 'gw-napi' in self.base_url:
            session_base_url = "https://napi.kotaksecurities.com/"
        else:
            session_base_url = "https://mnapi.kotaksecurities.com/"
        
        url = f"{session_base_url}oauth2/token"
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
                return True  # Continue anyway - we'll use edit_token
        except Exception as e:
            print(f"⚠️  Session init error: {e} - Will try using edit_token")
            return True  # Continue anyway
    
    def authenticate(self):
        """Complete authentication flow - Direct REST API (no SDK)"""
        print("\n🔐 Starting Authentication...")
        
        if not self.load_credentials():
            return False
        
        # Try to get bearer_token from session_init (needed for REST quotes API)
        # But if consumer_secret is missing, continue anyway
        self.session_init_for_bearer_token()
        
        # Get base URL (optional, but useful for REST quotes API)
        if not self.base_url:
            self.get_base_url()
        
        # Direct TOTP login
        if not self.totp_login():
            return False
        
        if not self.totp_validate():
            return False
        
        print("✅ Authentication complete!\n")
        return True
    
    def get_sensex_cmp(self):
        """Get SENSEX Current Market Price (CMP) via WebSocket"""
        print("  📡 Fetching SENSEX CMP...")
        
        ws_url = "wss://mlhsm.kotaksecurities.com"
        
        sensex_cmp = None
        connection_ok = False
        subscription_ok = False
        data_received = threading.Event()
        hs_wrapper = HSWrapper()
        global ws, topic_list
        
        def on_open(ws_conn):
            nonlocal connection_ok
            global ws
            ws = ws_conn  # Set global for acknowledgements
            print("  ✓ WebSocket connected")
            
            conn_bytes = prepareConnectionRequest2(self.edit_token, self.edit_sid)
            ws_conn.send(conn_bytes, opcode=0x2)
        
        def on_message(ws_conn, message):
            nonlocal connection_ok, subscription_ok, sensex_cmp
            global ws
            ws = ws_conn  # Set global for acknowledgements
            
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
                                
                                # Subscribe to SENSEX
                                scrips = "bse_cm|SENSEX"
                                sub_bytes = prepareSubsUnSubsRequest(
                                    scrips,
                                    BinRespTypes["SUBSCRIBE_TYPE"],
                                    INDEX_PREFIX,
                                    2
                                )
                                if sub_bytes:
                                    ws_conn.send(sub_bytes, opcode=0x2)
                                    print("  ✓ Subscribed to SENSEX")
                            
                            elif item.get('type') in ['sub', 'ifs']:
                                subscription_ok = True
                                print("  ✓ Subscription acknowledged")
                    
                    # Get SENSEX data
                    if isinstance(parsed, list):
                        for item in parsed:
                            if isinstance(item, dict):
                                token = item.get('tk')
                                if token == 'SENSEX' or not token:
                                    # Get LTP (iv for indices, ltp for scrips)
                                    ltp = item.get('iv') or item.get('ltp')
                                    if ltp:
                                        sensex_cmp = float(ltp)
                                        print(f"  ✓ SENSEX CMP: ₹{sensex_cmp:.2f}")
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
                print("  ⚠️  Timeout waiting for SENSEX CMP")
            
            try:
                ws_connection.close()
            except:
                pass
            
            return sensex_cmp
            
        except Exception as e:
            print(f"  ❌ WebSocket error: {e}")
            return None
    
    def filter_strikes_around_cmp(self, tokens_data, cmp, num_strikes=40):
        """Filter tokens to get num_strikes above and below CMP for both CE and PE"""
        # Get all unique strike prices
        strike_prices = {}
        for token_info in tokens_data:
            try:
                strike = float(token_info['strike_price'])
                option_type = token_info['option_type']
                
                if strike not in strike_prices:
                    strike_prices[strike] = {'CE': [], 'PE': []}
                
                strike_prices[strike][option_type].append(token_info)
            except (ValueError, KeyError):
                continue
        
        # Sort strikes
        sorted_strikes = sorted(strike_prices.keys())
        
        # Find ATM (closest to CMP)
        atm_strike = min(sorted_strikes, key=lambda x: abs(x - cmp))
        atm_idx = sorted_strikes.index(atm_strike)
        
        # Get strikes around ATM
        # Start index for ITM strikes (below ATM for CE, above ATM for PE)
        start_idx = max(0, atm_idx - num_strikes)
        # End index for OTM strikes (above ATM for CE, below ATM for PE)
        end_idx = min(len(sorted_strikes), atm_idx + num_strikes + 1)
        
        selected_strikes = sorted_strikes[start_idx:end_idx]
        
        # Collect tokens for selected strikes
        filtered_tokens = []
        for strike in selected_strikes:
            if strike in strike_prices:
                # Add CE options
                filtered_tokens.extend(strike_prices[strike]['CE'])
                # Add PE options
                filtered_tokens.extend(strike_prices[strike]['PE'])
        
        return filtered_tokens
    
    def filter_strikes_optimized(self, tokens_data, cmp, otm_strikes=25, itm_atm_strikes=67):
        """Optimized filter: 25 OTM + 67 ITM+ATM strikes
        This reduces load while keeping meaningful OI data (far OTM has low OI impact)
        
        Strategy:
        - 67 ITM+ATM strikes around CMP (covers most active trading)
        - 25 OTM strikes above CMP (for CE OTM)
        - 25 OTM strikes below CMP (for PE OTM)
        """
        # Get all unique strike prices
        strike_prices = {}
        for token_info in tokens_data:
            try:
                strike = float(token_info['strike_price'])
                option_type = token_info['option_type']
                
                if strike not in strike_prices:
                    strike_prices[strike] = {'CE': [], 'PE': []}
                
                strike_prices[strike][option_type].append(token_info)
            except (ValueError, KeyError):
                continue
        
        if not strike_prices:
            return []
        
        # Sort strikes
        sorted_strikes = sorted(strike_prices.keys())
        
        # Find ATM (closest to CMP)
        atm_strike = min(sorted_strikes, key=lambda x: abs(x - cmp))
        atm_idx = sorted_strikes.index(atm_strike)
        
        # Calculate ITM+ATM range: strikes around ATM (covers both CE and PE ITM)
        itm_atm_half = (itm_atm_strikes / 2)
        itm_atm_start_idx = max(0, int(atm_idx - itm_atm_half))
        itm_atm_end_idx = min(len(sorted_strikes), int(atm_idx + itm_atm_half + 1))
        
        # OTM strikes above CMP (for CE OTM) - take last N strikes
        otm_above_start_idx = itm_atm_end_idx
        otm_above_end_idx = len(sorted_strikes)
        otm_above_count = min(otm_strikes, otm_above_end_idx - otm_above_start_idx)
        otm_above_actual_start = max(otm_above_start_idx, otm_above_end_idx - otm_above_count)
        
        # OTM strikes below CMP (for PE OTM) - take first N strikes
        otm_below_start_idx = 0
        otm_below_end_idx = itm_atm_start_idx
        otm_below_count = min(otm_strikes, otm_below_end_idx - otm_below_start_idx)
        otm_below_actual_end = min(otm_below_end_idx, otm_below_start_idx + otm_below_count)
        
        # Collect selected strikes
        selected_strikes = set()
        
        # Add ITM+ATM strikes (around CMP)
        selected_strikes.update(sorted_strikes[itm_atm_start_idx:itm_atm_end_idx])
        
        # Add OTM strikes above CMP (CE OTM)
        if otm_above_count > 0:
            selected_strikes.update(sorted_strikes[otm_above_actual_start:otm_above_end_idx])
        
        # Add OTM strikes below CMP (PE OTM)
        if otm_below_count > 0:
            selected_strikes.update(sorted_strikes[otm_below_start_idx:otm_below_actual_end])
        
        # Sort selected strikes
        selected_strikes_sorted = sorted(selected_strikes)
        
        # Collect tokens for selected strikes
        filtered_tokens = []
        for strike in selected_strikes_sorted:
            if strike in strike_prices:
                # Add CE options
                filtered_tokens.extend(strike_prices[strike]['CE'])
                # Add PE options
                filtered_tokens.extend(strike_prices[strike]['PE'])
        
        return filtered_tokens
    
    def get_quotes_via_websocket(self, tokens, exchange_segment="nse_fo", timeout_seconds=30, persistent=False):
        """Fetch quotes for multiple tokens via WebSocket
        
        Args:
            tokens: List of tokens to fetch
            exchange_segment: Exchange segment (default: nse_fo)
            timeout_seconds: Timeout for initial data collection
            persistent: If True, keeps connection open and returns (ws_connection, all_quotes) tuple
                       If False, closes after collecting data and returns all_quotes dict
        """
        if persistent:
            print(f"📡 Opening persistent WebSocket for {len(tokens)} tokens...")
        else:
            print(f"📡 Fetching {len(tokens)} tokens via WebSocket...")
        
        ws_url = "wss://mlhsm.kotaksecurities.com"
        
        # Store quotes data: {token_str: quote_dict}
        all_quotes = {}
        connection_ok = False
        subscription_ok = False
        hs_wrapper = HSWrapper()
        global ws, topic_list
        
        # Convert all tokens to strings for comparison, and also create int set for fallback matching
        token_set = {str(t).strip() for t in tokens}
        token_int_set = set()
        for t in tokens:
            try:
                token_int_set.add(int(str(t).strip()))
            except (ValueError, TypeError):
                pass
        tokens_collected_set = set()
        data_received_event = threading.Event()
        
        def on_open(ws_conn):
            nonlocal connection_ok
            global ws
            ws = ws_conn  # Set global for acknowledgements
            print("  ✓ WebSocket connected")
            
            conn_bytes = prepareConnectionRequest2(self.edit_token, self.edit_sid)
            ws_conn.send(conn_bytes, opcode=0x2)
            print(f"  ✓ Connection message sent")
        
        def on_message(ws_conn, message):
            nonlocal connection_ok, subscription_ok, all_quotes, tokens_collected_set
            global ws
            ws = ws_conn  # Set global for acknowledgements
            
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
                                scrips = "&".join([f"{exchange_segment}|{token}" for token in tokens])
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
                                    # Don't set data_received_event here - wait for actual data
                    
                    # Market data updates - continuously update quotes
                    if isinstance(parsed, list):
                        for item in parsed:
                            if isinstance(item, dict):
                                token = item.get('tk')
                                if token:
                                    token_str = str(token).strip()
                                    # Try to match as string first, then as integer
                                    token_matched = False
                                    matched_token_key = None
                                    
                                    if token_str in token_set:
                                        token_matched = True
                                        matched_token_key = token_str
                                    else:
                                        # Try matching as integer
                                        try:
                                            token_int = int(token_str)
                                            if token_int in token_int_set:
                                                # Find the string version of this token
                                                for t in tokens:
                                                    if int(str(t).strip()) == token_int:
                                                        matched_token_key = str(t).strip()
                                                        token_matched = True
                                                        break
                                        except (ValueError, TypeError):
                                            pass
                                    
                                    # Debug: log first few received tokens to diagnose format issues
                                    if len(tokens_collected_set) == 0 and len(all_quotes) < 3:
                                        print(f"  🔍 Debug: Received token '{token_str}' (type: {type(token).__name__}), matched: {token_matched}")
                                        if not token_matched:
                                            sample_expected = list(token_set)[:3]
                                            print(f"  🔍 Debug: Token not in expected set. Expected format (sample): {sample_expected}")
                                    
                                    # Only collect data for tokens we requested
                                    if token_matched and matched_token_key:
                                        # Store/update complete quote data (use matched_token_key for consistency)
                                        all_quotes[matched_token_key] = item
                                        
                                        # Track which tokens we've received (for initial collection)
                                        if matched_token_key not in tokens_collected_set:
                                            tokens_collected_set.add(matched_token_key)
                                            
                                            # Print progress every 20 tokens or when complete
                                            if len(tokens_collected_set) % 20 == 0 or len(tokens_collected_set) == len(token_set):
                                                print(f"  ✓ Collected: {len(tokens_collected_set)}/{len(token_set)} tokens...")
                                            
                                            # Signal that we've received at least some data
                                            if not persistent and len(tokens_collected_set) == 1:
                                                data_received_event.set()  # Signal that data has started arriving
                                            
                                            # If we got all tokens, signal completion (only for non-persistent mode)
                                            if not persistent and len(tokens_collected_set) >= len(token_set):
                                                print(f"  ✓ All {len(token_set)} tokens collected!")
                                                data_received_event.set()
                                                return
                                        
            except Exception as e:
                print(f"  ⚠️  Error parsing message: {e}")
        
        def on_error(ws, error):
            print(f"  ⚠️  WebSocket error: {error}")
        
        def on_close(ws, close_status_code, close_msg):
            if not persistent:
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
            
            if persistent:
                # For persistent mode, wait for subscription acknowledgment, then return connection
                print(f"  ⏳ Waiting for subscription acknowledgment...")
                data_received_event.wait(timeout=10)  # Wait for subscription ack
                if subscription_ok:
                    print(f"  ✓ Persistent WebSocket ready - will stay open")
                    return ws_connection, all_quotes
                else:
                    print(f"  ⚠️  Subscription not acknowledged in time")
                    try:
                        ws_connection.close()
                    except:
                        pass
                    return None, {}
            else:
                # For non-persistent mode, wait for all data then close
                timeout = timeout_seconds
                print(f"  ⏳ Waiting for data (max {timeout:.1f}s)...")
                
                # First wait for subscription acknowledgment
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
                
                # Now wait for actual data to arrive (give it more time after subscription)
                # Wait for at least some data to arrive
                data_received_event.wait(timeout=min(timeout, 10))
                
                # If we got some data, wait a bit more to collect more
                if len(tokens_collected_set) > 0:
                    remaining_time = timeout - (time.time() - subscription_wait_start)
                    if remaining_time > 0:
                        # Wait a bit more to collect additional tokens
                        time.sleep(min(2.0, remaining_time))
                
                if len(tokens_collected_set) < len(token_set):
                    missing = len(token_set) - len(tokens_collected_set)
                    print(f"  ⚠️  Collected {len(tokens_collected_set)}/{len(token_set)} tokens ({missing} missing)")
                    # Debug: show a few sample tokens we're expecting vs what we got
                    if len(tokens_collected_set) == 0:
                        print(f"  🔍 Debug: Expected tokens (sample): {list(token_set)[:5]}")
                        print(f"  🔍 Debug: No tokens received - check if token format matches")
                else:
                    print(f"  ✓ All tokens collected!")
                
                # Close connection after collecting data
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
            return {} if not persistent else (None, {})

    def get_quotes_via_rest_batch(self, tokens, exchange_segment="nse_fo"):
        """Fallback: Fetch quotes via direct REST API (no SDK) in batches."""
        if not self.base_url:
            print("  ⚠️  No base_url available for REST quotes API")
            return {}
        
        all_quotes = {}
        batch_size = 50
        
        # Use bearer_token if available, otherwise fall back to edit_token
        auth_token = self.bearer_token if self.bearer_token else self.edit_token
        if not auth_token:
            print("  ⚠️  No auth token available for REST quotes API")
            return {}
        
        for i in range(0, len(tokens), batch_size):
            batch = tokens[i:i+batch_size]
            
            # Format: exchange_segment|token1,exchange_segment|token2,...
            neo_symbol_str = ",".join([f"{exchange_segment}|{token}" for token in batch])
            encoded_neo_symbol_str = url_quote(neo_symbol_str)
            
            # Determine which endpoint to use based on base_url
            if 'gw-napi' in self.base_url:
                url_path = f"apim/quotes/1.0/quotes/neosymbol/{encoded_neo_symbol_str}/all"
            else:
                url_path = f"apim/quotes/2.0/quotes/neosymbol/{encoded_neo_symbol_str}/all"
            
            url = f"{self.base_url}{url_path}"
            headers = {
                'Authorization': f'Bearer {auth_token}',
                'Content-Type': 'application/json'
            }
            
            try:
                response = requests.get(url, headers=headers, verify=False, timeout=30)
                if response.status_code == 200:
                    resp_data = response.json()
                    quotes = resp_data.get('data', {}).get('quotes', []) if isinstance(resp_data, dict) else []
                    if not quotes and isinstance(resp_data, dict) and 'quotes' in resp_data:
                        quotes = resp_data.get('quotes', [])
                    
                    for q in quotes:
                        tk = str(q.get('tk') or q.get('instrument_token') or '').strip()
                        if tk:
                            all_quotes[tk] = q
                else:
                    print(f"  ⚠️  REST quotes batch failed: {response.status_code} - {response.text[:100]}")
            except Exception as e:
                print(f"  ⚠️  REST quotes batch failed: {e}")
            time.sleep(0.1)
        
        return all_quotes
    
    def open_persistent_websocket(self, tokens, batch_quotes, shared_quotes_dict, exchange_segment="bse_fo"):
        """Open a persistent WebSocket connection that stays open and updates shared quotes dict"""
        ws_url = "wss://mlhsm.kotaksecurities.com"
        
        connection_ok = False
        subscription_ok = False
        hs_wrapper = HSWrapper()
        token_set = {str(t).strip() for t in tokens}
        subscription_event = threading.Event()
        data_received_event = threading.Event()
        tokens_collected = set()
        global ws, topic_list
        
        def on_open(ws_conn):
            nonlocal connection_ok
            global ws
            ws = ws_conn  # Set global for acknowledgements
            conn_bytes = prepareConnectionRequest2(self.edit_token, self.edit_sid)
            ws_conn.send(conn_bytes, opcode=0x2)
        
        def on_message(ws_conn, message):
            nonlocal connection_ok, subscription_ok, tokens_collected
            global ws
            ws = ws_conn  # Set global for acknowledgements
            
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
                                time.sleep(0.3)
                                
                                # Subscribe to tokens
                                scrips = "&".join([f"{exchange_segment}|{token}" for token in tokens])
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
                    
                    # Market data updates - continuously update shared dictionary
                    if isinstance(parsed, list):
                        for item in parsed:
                            if isinstance(item, dict):
                                token = item.get('tk')
                                if token:
                                    token_str = str(token)
                                    if token_str in token_set:
                                        # Update both batch and shared dictionaries
                                        batch_quotes[token_str] = item
                                        shared_quotes_dict[token_str] = item
                                        
                                        # Track when we receive first data
                                        if token_str not in tokens_collected:
                                            tokens_collected.add(token_str)
                                            
                                            # Signal when we get some data (at least 20% of tokens)
                                            if len(tokens_collected) >= max(1, len(token_set) * 0.2):
                                                data_received_event.set()
                                        
            except Exception as e:
                print(f"    ⚠️  Error parsing message: {e}")
        
        def on_error(ws, error):
            print(f"    ⚠️  WebSocket error: {error}")
        
        def on_close(ws, close_status_code, close_msg):
            print(f"    ⚠️  WebSocket closed unexpectedly")
        
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
            
            # Wait for subscription acknowledgment first
            if not subscription_event.wait(timeout=10):
                print(f"    ⚠️  Subscription not acknowledged")
                try:
                    ws_connection.close()
                except:
                    pass
                return None
            
            # Then wait for initial data to arrive (wait longer for actual data)
            print(f"    ⏳ Waiting for initial data...")
            if data_received_event.wait(timeout=20):  # Wait up to 20 seconds for data
                print(f"    ✓ Received initial data: {len(tokens_collected)}/{len(token_set)} tokens")
                return ws_connection
            else:
                print(f"    ⚠️  No data received yet, but connection is open (data may arrive later)")
                return ws_connection  # Still return connection even if no data yet - it will update
                
        except Exception as e:
            print(f"    ❌ WebSocket error: {e}")
            return None
    
    def load_option_tokens_from_csv(self, csv_file):
        """Load option tokens from CSV file"""
        tokens_data = []
        try:
            df = pd.read_csv(csv_file)
            
            # Expected columns: pSymbol (numeric instrument token), pOptionType. pScripRefKey is kept for reference
            required_cols = ['pSymbol', 'pOptionType']
            if not all(col in df.columns for col in required_cols):
                print(f"❌ CSV missing required columns: {required_cols}")
                return []
            
            for _, row in df.iterrows():
                # Use pSymbol as instrument token (numeric), e.g., 47667
                token_src = row.get('pSymbol')
                token = str(token_src).strip() if token_src is not None else ''
                option_type = row['pOptionType']
                strike_price = row.get('Strike Price', 'N/A')
                expiry = row.get('Expiry', 'N/A')
                scrip_ref_key = row.get('pScripRefKey', 'N/A')
                
                tokens_data.append({
                    'token': token,
                    'option_type': option_type,
                    'strike_price': strike_price,
                    'expiry': expiry,
                    'scrip_ref_key': scrip_ref_key
                })
            
            print(f"✓ Loaded {len(tokens_data)} option tokens from CSV")
            return tokens_data
        except Exception as e:
            print(f"❌ Error loading CSV: {e}")
            import traceback
            traceback.print_exc()
            return []
    
    def find_latest_output_csv(self, output_dir='outputs'):
        """Find the latest output CSV file from sensexcurrentexpirypsymbol.py"""
        today_str = datetime.now().strftime('%Y%m%d')
        # Look for files matching: sensex_bse_expiry_YYYYMMDD_*.csv
        today_pattern = os.path.join(output_dir, f"sensex_bse_expiry_{today_str}_*.csv")
        candidates = glob.glob(today_pattern)
        
        if not candidates:
            # Fallback to any sensex_bse_expiry file
            pattern = os.path.join(output_dir, "sensex_bse_expiry_*.csv")
            candidates = glob.glob(pattern)
        
        if not candidates:
            return None
        
        # Sort by modification time, get latest
        candidates.sort(key=lambda x: os.path.getmtime(x), reverse=True)
        return candidates[0]
    
    def fetch_all_strikes_data(self, input_csv=None, batch_size=10, fetch_interval=None, oi_calc_interval=None, continuous_mode=False):
        """Fetch live data for all option tokens"""
        print("="*80)
        print("📊 FETCH ALL SENSEX STRIKES LIVE DATA")
        print("="*80)
        
        # Ask for intervals if not provided and in continuous mode
        if continuous_mode:
            if fetch_interval is None:
                try:
                    fetch_input = input("\n⏱️  Enter fetch interval (seconds) for live market data updates [default: 5]: ").strip()
                    fetch_interval = int(fetch_input) if fetch_input else 5
                except ValueError:
                    print("⚠️  Invalid input, using default: 5 seconds")
                    fetch_interval = 5
            
            if oi_calc_interval is None:
                try:
                    oi_input = input("⏱️  Enter OI calculation interval (seconds) [default: 10]: ").strip()
                    oi_calc_interval = int(oi_input) if oi_input else 10
                except ValueError:
                    print("⚠️  Invalid input, using default: 10 seconds")
                    oi_calc_interval = 10
            
            print(f"\n✅ Intervals set:")
            print(f"   📡 Fetch interval: {fetch_interval} seconds")
            print(f"   📊 OI calculation interval: {oi_calc_interval} seconds\n")
        
        # Authenticate
        if not self.authenticate():
            print("❌ Authentication failed")
            return
        
        # Find input CSV if not provided
        if not input_csv:
            input_csv = self.find_latest_output_csv()
            if not input_csv:
                print("❌ Could not find input CSV file")
                print("   Please run sensexcurrentexpirypsymbol.py first or specify CSV path")
                return
        
        print(f"\n📂 Reading input CSV: {input_csv}")
        tokens_data = self.load_option_tokens_from_csv(input_csv)
        
        if not tokens_data:
            print("❌ No tokens found in CSV")
            return
        
        print(f"\n📡 Step 1: Getting SENSEX CMP (Current Market Price)...")
        
        # First, get SENSEX spot price
        sensex_cmp = self.get_sensex_cmp()
        if not sensex_cmp:
            print("❌ Could not get SENSEX CMP. Cannot filter strikes.")
            return
        
        print(f"\n📊 SENSEX CMP: ₹{sensex_cmp:.2f}")
        print(f"\n📡 Step 2: Filtering strikes (25 OTM + 67 ITM+ATM - optimized)...")
        
        # Filter tokens with optimized strategy: 25 OTM + 67 ITM+ATM
        # This reduces load while keeping meaningful OI data (far OTM has low OI impact)
        filtered_tokens_data = self.filter_strikes_optimized(tokens_data, sensex_cmp, otm_strikes=25, itm_atm_strikes=67)
        
        if not filtered_tokens_data:
            print("❌ No tokens found within the strike range")
            return
        
        print(f"   ✓ Filtered to {len(filtered_tokens_data)} tokens:")
        print(f"     - {len([t for t in filtered_tokens_data if t['option_type'] == 'CE'])} CE options")
        print(f"     - {len([t for t in filtered_tokens_data if t['option_type'] == 'PE'])} PE options")
        
        # Sort tokens by distance from CMP (nearest first) for priority fetching
        def get_strike_distance(token_info):
            try:
                strike = float(token_info.get('strike_price', 0))
                return abs(strike - sensex_cmp)
            except (ValueError, TypeError):
                return float('inf')  # Put invalid strikes at end
        
        print(f"\n📊 Sorting strikes by distance from CMP (nearest first)...")
        filtered_tokens_data = sorted(filtered_tokens_data, key=get_strike_distance)
        print(f"   ✓ Sorted - nearest strikes will be fetched first")
        
        # Extract tokens list - convert to strings for API
        all_tokens = [str(item['token']).strip() for item in filtered_tokens_data]
        
        print(f"\n📡 Step 3: Fetching data for {len(all_tokens)} tokens via WebSocket...")
        print(f"   Using only filtered tokens from nearest expiry CSV file.\n")
        
        all_quotes_data = {}
        
        # API limitation: Maximum 100 scrips per subscription request
        # Split into batches of 100
        max_batch_size = 100
        total_batches = (len(all_tokens) + max_batch_size - 1) // max_batch_size
        
        print(f"📦 Subscribing to {len(all_tokens)} tokens in {total_batches} batches (max {max_batch_size} per batch)...")
        
        for batch_idx in range(0, len(all_tokens), max_batch_size):
            batch_num = (batch_idx // max_batch_size) + 1
            batch_tokens = all_tokens[batch_idx:batch_idx + max_batch_size]
            
            print(f"\n  📦 Batch {batch_num}/{total_batches}: Fetching {len(batch_tokens)} tokens...")
            
            # Calculate timeout based on batch size - give more time for data to arrive
            timeout_sec = min(30, max(15, len(batch_tokens) * 0.3))
            
            quotes = self.get_quotes_via_websocket(batch_tokens, exchange_segment="bse_fo", timeout_seconds=timeout_sec)
            
            # Store quotes
            all_quotes_data.update(quotes)
            print(f"     ✓ Collected {len(quotes)} quotes (total: {len(all_quotes_data)}/{len(all_tokens)})")
            
            # Small delay between batches
            if batch_idx + max_batch_size < len(all_tokens):
                time.sleep(0.5)
        
        if not all_quotes_data:
            print(f"\n❌ WebSocket didn't return any data")
            print(f"   Falling back to REST Quotes API in batches...")
            all_quotes_data = self.get_quotes_via_rest_batch(all_tokens, exchange_segment="bse_fo")
            if not all_quotes_data:
                print(f"   ❌ REST fallback also returned no data. Aborting.")
                return
        
        print(f"\n✓ Fetched data for {len(all_quotes_data)} tokens")
        
        # Helper function to safely get values from quote dict
        def safe_get(quote_dict, *keys):
            """Try multiple keys to get a value"""
            for key in keys:
                if key in quote_dict and quote_dict[key] is not None:
                    val = quote_dict[key]
                    # Handle N/A values and empty strings
                    if val == 'N/A' or val == '':
                        continue
                    return val
            return 'N/A'
        
        # Combine with filtered token data and create output
        output_data = []
        current_time = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        
        # Add SENSEX CMP as first row
        sensex_cmp_row = {
            'token': 'SENSEX',
            'pSymbol': 'SENSEX',
            'pOptionType': 'INDEX',
            'Strike Price': 'N/A',
            'Expiry': 'N/A',
            'pScripRefKey': 'SENSEX_INDEX',
            'ltp': sensex_cmp,
            'ltp_update_time': current_time,
            'ltq': 'N/A',
            'lo': 'N/A',
            'h': 'N/A',
            'lcl': 'N/A',
            'ucl': 'N/A',
            'op': 'N/A',
            'c': 'N/A',
            'oi': 'N/A',
            'oi_update_time': 'N/A',
            'mul': 'N/A',
            'prec': 'N/A',
            'cng': 'N/A',
            'nc': 'N/A',
            'name': 'SENSEX',
            'tk': 'SENSEX',
            'e': 'bse_cm',
            'ts': 'SENSEX'
        }
        output_data.append(sensex_cmp_row)
        
        for token_info in filtered_tokens_data:
            token = str(token_info['token']).strip()  # Convert to string for consistent matching
            quote = all_quotes_data.get(token, {})
            
            # Get LTP - try ltp first, then iv (for indices), then c (close)
            ltp = safe_get(quote, 'ltp', 'iv', 'c')
            
            # Get LTQ - try ltq first, then v (volume might be different)
            ltq = safe_get(quote, 'ltq', 'v')
            
            # Get low - try lo, lowPrice, low
            lo = safe_get(quote, 'lo', 'lowPrice', 'low')
            
            # Get high - try h, highPrice, high
            h = safe_get(quote, 'h', 'highPrice', 'high')
            
            # Get circuit limits
            lcl = safe_get(quote, 'lcl', 'lowerCircuit', 'lower_circuit')
            ucl = safe_get(quote, 'ucl', 'upperCircuit', 'upper_circuit')
            
            # Get open - try op, openingPrice, open
            op = safe_get(quote, 'op', 'openingPrice', 'open')
            
            # Get close - try c, ic (index close), close
            c = safe_get(quote, 'c', 'ic', 'close')
            
            # Get OI
            oi = safe_get(quote, 'oi', 'openInterest', 'open_interest')
            
            # Get multiplier and precision
            mul = safe_get(quote, 'mul', 'multiplier')
            prec = safe_get(quote, 'prec', 'precision')
            
            # Get change values
            cng = safe_get(quote, 'cng', 'change')
            nc = safe_get(quote, 'nc', 'changePct', 'nc', 'change_pct')
            
            # Get name, token, exchange, trading symbol
            name = safe_get(quote, 'name', 'nm')
            tk = safe_get(quote, 'tk', 'token', 'instrument_token')
            e = safe_get(quote, 'e', 'exchange', 'exchange_segment')
            ts = safe_get(quote, 'ts', 'tradingSymbol', 'trading_symbol')
            
            # Determine update times - only set if we got actual values (not N/A)
            ltp_update_time = current_time if ltp != 'N/A' else 'N/A'
            oi_update_time = current_time if oi != 'N/A' else 'N/A'
            
            row_data = {
                'token': token,
                'pSymbol': token,
                'pOptionType': token_info['option_type'],
                'Strike Price': token_info['strike_price'],
                'Expiry': token_info['expiry'],
                'pScripRefKey': token_info['scrip_ref_key'],
                'ltp': ltp,
                'ltp_update_time': ltp_update_time,
                'ltq': ltq,
                'lo': lo,
                'h': h,
                'lcl': lcl,
                'ucl': ucl,
                'op': op,
                'c': c,
                'oi': oi,
                'oi_update_time': oi_update_time,
                'mul': mul,
                'prec': prec,
                'cng': cng,
                'nc': nc,
                'name': name if name != 'N/A' else 'N/A',
                'tk': tk if tk != 'N/A' else token,
                'e': e if e != 'N/A' else 'nse_fo',
                'ts': ts if ts != 'N/A' else token_info['scrip_ref_key']
            }
            
            output_data.append(row_data)
        
        # Calculate total OI for Call and Put sides from filtered_tokens_data (source data)
        # This matches the NIFTY calculation approach for consistency
        total_oi_ce = 0
        total_oi_pe = 0
        
        for token_info in filtered_tokens_data:
            token = str(token_info['token']).strip()
            quote = all_quotes_data.get(token, {})
            option_type = token_info['option_type']
            
            oi_value = safe_get(quote, 'oi', 'openInterest', 'open_interest')
            
            try:
                if oi_value != 'N/A' and oi_value is not None:
                    oi_float = float(oi_value)
                    if option_type == 'CE':
                        total_oi_ce += oi_float
                    elif option_type == 'PE':
                        total_oi_pe += oi_float
            except (ValueError, TypeError):
                pass
        
        # Add OI totals to output data as summary rows
        if output_data:
            # Add summary row for Call OI
            summary_ce = {
                'token': 'SUMMARY_CE',
                'pSymbol': 'TOTAL_CE_OI',
                'pOptionType': 'CE',
                'Strike Price': 'N/A',
                'Expiry': filtered_tokens_data[0]['expiry'] if filtered_tokens_data else 'N/A',
                'pScripRefKey': 'TOTAL_CE_OPEN_INTEREST',
                'ltp': 'N/A',
                'ltp_update_time': 'N/A',
                'ltq': 'N/A',
                'lo': 'N/A',
                'h': 'N/A',
                'lcl': 'N/A',
                'ucl': 'N/A',
                'op': 'N/A',
                'c': 'N/A',
                'oi': int(total_oi_ce),
                'oi_update_time': current_time,
                'mul': 'N/A',
                'prec': 'N/A',
                'cng': 'N/A',
                'nc': 'N/A',
                'name': 'Total CE OI',
                'tk': 'TOTAL_CE_OI',
                'e': 'nse_fo',
                'ts': 'TOTAL_CALL_OPEN_INTEREST'
            }
            
            # Add summary row for Put OI
            summary_pe = {
                'token': 'SUMMARY_PE',
                'pSymbol': 'TOTAL_PE_OI',
                'pOptionType': 'PE',
                'Strike Price': 'N/A',
                'Expiry': filtered_tokens_data[0]['expiry'] if filtered_tokens_data else 'N/A',
                'pScripRefKey': 'TOTAL_PE_OPEN_INTEREST',
                'ltp': 'N/A',
                'ltp_update_time': 'N/A',
                'ltq': 'N/A',
                'lo': 'N/A',
                'h': 'N/A',
                'lcl': 'N/A',
                'ucl': 'N/A',
                'op': 'N/A',
                'c': 'N/A',
                'oi': int(total_oi_pe),
                'oi_update_time': current_time,
                'mul': 'N/A',
                'prec': 'N/A',
                'cng': 'N/A',
                'nc': 'N/A',
                'name': 'Total PE OI',
                'tk': 'TOTAL_PE_OI',
                'e': 'nse_fo',
                'ts': 'TOTAL_PUT_OPEN_INTEREST'
            }
            
            output_data.append(summary_ce)
            output_data.append(summary_pe)
        
        # Save to CSV
        output_dir = 'outputs'
        os.makedirs(output_dir, exist_ok=True)
        
        today_str = datetime.now().strftime('%Y%m%d')
        expiry_str = filtered_tokens_data[0]['expiry'] if filtered_tokens_data else 'UNKNOWN'
        cmp_str = f"{sensex_cmp:.0f}" if sensex_cmp else 'UNKNOWN'
        output_filename = f"sensex_bse_strikes_data_{today_str}_{expiry_str}_CMP{cmp_str}.csv"
        output_path = os.path.join(output_dir, output_filename)
        
        # Create DataFrame and save
        df_output = pd.DataFrame(output_data)
        df_output.to_csv(output_path, index=False, encoding='utf-8')
        
        print(f"\n💾 Saved output CSV: {output_path}")
        print(f"   Total rows: {len(output_data)} (including 1 SENSEX row + 2 summary rows)")
        print(f"   Tokens with data: {len(all_quotes_data)}")
        print(f"   Tokens with N/A: {len(filtered_tokens_data) - len(all_quotes_data)}")
        print(f"   SENSEX CMP: ₹{sensex_cmp:.2f} (added to CSV)")
        print(f"   Strikes filtered: 25 OTM + 67 ITM+ATM (optimized)")
        print(f"\n📊 OI Totals Calculated:")
        print(f"   Total CE OI: {int(total_oi_ce):,}")
        print(f"   Total PE OI: {int(total_oi_pe):,}")
        print(f"   OI Ratio (CE/PE): {(total_oi_ce / total_oi_pe if total_oi_pe > 0 else 0):.2f}")
        
        # Check if today's file already exists before saving
        today_date = datetime.now().date()
        file_exists_today = False
        
        # Check existing files (both old and new filename patterns)
        pattern1 = os.path.join(output_dir, f"sensex_bse_all_strikes_data_*.csv")
        pattern2 = os.path.join(output_dir, f"sensex_bse_strikes_data_*.csv")
        candidates = glob.glob(pattern1) + glob.glob(pattern2)
        
        for existing_path in candidates:
            existing_name = os.path.basename(existing_path)
            
            # Check modification date
            file_mod_time = datetime.fromtimestamp(os.path.getmtime(existing_path))
            file_mod_date = file_mod_time.date()
            
            # Check filename date (both old and new patterns)
            if (existing_name.startswith(f"sensex_bse_all_strikes_data_{today_str}_") or 
                existing_name.startswith(f"sensex_bse_strikes_data_{today_str}_")):
                file_exists_today = True
                # Delete old file if it's from today but different name
                if existing_name != output_filename:
                    try:
                        os.remove(existing_path)
                        print(f"🧹 Deleted old file: {existing_name}")
                    except:
                        pass
        
        # Delete files from previous dates
        for existing_path in candidates:
            existing_name = os.path.basename(existing_path)
            file_mod_time = datetime.fromtimestamp(os.path.getmtime(existing_path))
            file_mod_date = file_mod_time.date()
            
            if file_mod_date < today_date and existing_path != output_path:
                try:
                    os.remove(existing_path)
                    print(f"🧹 Deleted old file: {existing_name} (date: {file_mod_date})")
                except:
                    pass
        
        print("\n✅ Complete!")
        return output_path
    
    def fetch_continuous_live_data(self, input_csv=None, fetch_interval=None, oi_calc_interval=None):
        """Continuously fetch live market data at specified intervals"""
        print("="*80)
        print("📊 CONTINUOUS LIVE MARKET DATA FETCHER")
        print("="*80)
        
        # Ask for intervals if not provided
        if fetch_interval is None:
            try:
                fetch_input = input("\n⏱️  Enter fetch interval (seconds) for live market data updates [default: 5]: ").strip()
                fetch_interval = int(fetch_input) if fetch_input else 5
            except ValueError:
                print("⚠️  Invalid input, using default: 5 seconds")
                fetch_interval = 5
        
        if oi_calc_interval is None:
            try:
                oi_input = input("⏱️  Enter OI calculation interval (seconds) [default: 10]: ").strip()
                oi_calc_interval = int(oi_input) if oi_input else 10
            except ValueError:
                print("⚠️  Invalid input, using default: 10 seconds")
                oi_calc_interval = 10
        
        print(f"\n✅ Intervals set:")
        print(f"   📡 Fetch interval: {fetch_interval} seconds")
        print(f"   📊 OI calculation interval: {oi_calc_interval} seconds\n")
        
        # Initial setup - get tokens and CMP
        print("📂 Initial Setup...")
        
        # Authenticate
        if not self.authenticate():
            print("❌ Authentication failed")
            return
        
        # Find input CSV
        if not input_csv:
            input_csv = self.find_latest_output_csv()
            if not input_csv:
                print("❌ Could not find input CSV file")
                return
        
        print(f"\n📂 Reading input CSV: {input_csv}")
        tokens_data = self.load_option_tokens_from_csv(input_csv)
        
        if not tokens_data:
            print("❌ No tokens found in CSV")
            return
        
        # Get SENSEX CMP and filter strikes
        print(f"\n📡 Getting SENSEX CMP...")
        sensex_cmp = self.get_sensex_cmp()
        if not sensex_cmp:
            print("❌ Could not get SENSEX CMP")
            return
        
        print(f"\n📊 SENSEX CMP: ₹{sensex_cmp:.2f}")
        filtered_tokens_data = self.filter_strikes_optimized(tokens_data, sensex_cmp, otm_strikes=25, itm_atm_strikes=67)
        
        if not filtered_tokens_data:
            print("❌ No tokens found within strike range")
            return
        
        # Sort tokens by distance from CMP (nearest first) for priority fetching
        def get_strike_distance(token_info):
            try:
                strike = float(token_info.get('strike_price', 0))
                return abs(strike - sensex_cmp)
            except (ValueError, TypeError):
                return float('inf')  # Put invalid strikes at end
        
        print(f"\n📊 Sorting strikes by distance from CMP (nearest first)...")
        filtered_tokens_data = sorted(filtered_tokens_data, key=get_strike_distance)
        print(f"   ✓ Sorted - nearest strikes will be fetched first (reduced delay)")
        
        all_tokens = [str(item['token']).strip() for item in filtered_tokens_data]
        
        print(f"\n✅ Setup complete!")
        print(f"   Filtered tokens: {len(all_tokens)}")
        print(f"   Fetch interval: {fetch_interval} seconds")
        print(f"   OI calculation interval: {oi_calc_interval} seconds")
        print(f"\n🔄 Starting continuous data fetching...")
        print(f"   Press Ctrl+C to stop\n")
        
        # Setup output file
        output_dir = 'outputs'
        os.makedirs(output_dir, exist_ok=True)
        today_str = datetime.now().strftime('%Y%m%d')
        expiry_str = filtered_tokens_data[0]['expiry'] if filtered_tokens_data else 'UNKNOWN'
        cmp_str = f"{sensex_cmp:.0f}"
        output_filename = f"sensex_bse_strikes_live_{today_str}_{expiry_str}_CMP{cmp_str}.csv"
        output_path = os.path.join(output_dir, output_filename)
        
        last_oi_calc_time = time.time()
        iteration = 0
        
        # Shared quotes data dictionary (updated by all WebSocket connections)
        all_quotes_data = {}
        ws_connections = []  # Store persistent WebSocket connections
        
        # Open persistent WebSocket connections once
        print(f"\n📡 Opening persistent WebSocket connections for {len(all_tokens)} tokens...")
        print(f"   These connections will stay open and receive live updates continuously.\n")
        
        max_batch_size = 100
        for batch_idx in range(0, len(all_tokens), max_batch_size):
            batch_tokens = all_tokens[batch_idx:batch_idx + max_batch_size]
            batch_num = (batch_idx // max_batch_size) + 1
            total_batches = (len(all_tokens) + max_batch_size - 1) // max_batch_size
            
            print(f"  📦 Batch {batch_num}/{total_batches}: Opening persistent connection for {len(batch_tokens)} tokens...")
            
            # Create a shared dictionary for this batch's quotes
            batch_quotes = {}
            
            # Open persistent connection
            ws_conn = self.open_persistent_websocket(batch_tokens, batch_quotes, all_quotes_data, exchange_segment="bse_fo")
            if ws_conn:
                ws_connections.append((batch_num, ws_conn, batch_tokens, batch_quotes))
                print(f"    ✓ Connection {batch_num} opened and will stay open")
            else:
                print(f"    ⚠️  Failed to open connection {batch_num}")
            
            if batch_idx + max_batch_size < len(all_tokens):
                time.sleep(0.3)
        
        # Wait for initial data to arrive
        print(f"\n  ⏳ Waiting for initial data to arrive...")
        initial_wait_start = time.time()
        while time.time() - initial_wait_start < 15:  # Wait up to 15 seconds for initial data
            time.sleep(0.5)
            if len(all_quotes_data) >= len(all_tokens) * 0.5:  # Got at least 50% of data
                break
        
        print(f"  ✓ Initial data collected: {len(all_quotes_data)}/{len(all_tokens)} tokens")
        print(f"  ✓ All WebSocket connections are open and will receive live updates\n")
        
        try:
            while True:
                iteration += 1
                current_time_str = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
                
                print(f"\n{'='*80}")
                print(f"🔄 Iteration #{iteration} - {current_time_str}")
                print(f"{'='*80}")
                
                # WebSocket connections are already open and updating all_quotes_data continuously
                # The shared_quotes_dict is being updated in real-time by all WebSocket connections
                print(f"📡 Collecting live data from persistent WebSocket connections...")
                print(f"   Current quotes available: {len(all_quotes_data)}/{len(all_tokens)} tokens")
                
                # Get fresh SENSEX CMP for this iteration
                print(f"\n📡 Getting SENSEX CMP for this iteration...")
                current_sensex_cmp = self.get_sensex_cmp()
                if not current_sensex_cmp:
                    current_sensex_cmp = sensex_cmp  # Fallback to initial CMP
                    print(f"   ⚠️  Using previous CMP: ₹{current_sensex_cmp:.2f}")
                else:
                    print(f"   ✓ Current CMP: ₹{current_sensex_cmp:.2f}")
                
                # Process and calculate OI
                should_calc_oi = (time.time() - last_oi_calc_time) >= oi_calc_interval

                # Load previous CSV (if exists) to preserve existing OI values
                previous_oi_by_token = {}
                previous_summary_oi = {}
                if os.path.exists(output_path):
                    try:
                        prev_df = pd.read_csv(output_path)
                        # Map token -> (oi, oi_update_time)
                        for _, prow in prev_df.iterrows():
                            ptok = str(prow.get('token', '')).strip()
                            poi = prow.get('oi') if 'oi' in prow else None
                            poi_time = prow.get('oi_update_time') if 'oi_update_time' in prow else 'N/A'
                            if ptok:
                                previous_oi_by_token[ptok] = (poi, poi_time)
                        # Store previous summary rows too
                        if 'SUMMARY_CE' in previous_oi_by_token:
                            previous_summary_oi['SUMMARY_CE'] = previous_oi_by_token['SUMMARY_CE']
                        if 'SUMMARY_PE' in previous_oi_by_token:
                            previous_summary_oi['SUMMARY_PE'] = previous_oi_by_token['SUMMARY_PE']
                    except Exception:
                        previous_oi_by_token = {}
                        previous_summary_oi = {}
                
                # Create output data
                output_data = []
                total_oi_ce = 0
                total_oi_pe = 0
                
                # Add SENSEX CMP as first row (updated with current CMP)
                sensex_cmp_row = {
                    'token': 'SENSEX',
                    'pSymbol': 'SENSEX',
                    'pOptionType': 'INDEX',
                    'Strike Price': 'N/A',
                    'Expiry': 'N/A',
                    'pScripRefKey': 'SENSEX_INDEX',
                    'ltp': current_sensex_cmp,
                    'ltp_update_time': current_time_str,
                    'ltq': 'N/A',
                    'lo': 'N/A',
                    'h': 'N/A',
                    'lcl': 'N/A',
                    'ucl': 'N/A',
                    'op': 'N/A',
                    'c': 'N/A',
                    'oi': 'N/A',
                    'oi_update_time': 'N/A',
                    'mul': 'N/A',
                    'prec': 'N/A',
                    'cng': 'N/A',
                    'nc': 'N/A',
                    'name': 'SENSEX',
                    'tk': 'SENSEX',
                    'e': 'bse_cm',
                    'ts': 'SENSEX'
                }
                output_data.append(sensex_cmp_row)
                
                def safe_get(quote_dict, *keys):
                    for key in keys:
                        if key in quote_dict and quote_dict[key] is not None:
                            val = quote_dict[key]
                            if val == 'N/A' or val == '':
                                continue
                            return val
                    return 'N/A'
                
                for token_info in filtered_tokens_data:
                    token = str(token_info['token']).strip()
                    quote = all_quotes_data.get(token, {})
                    
                    # Extract fields
                    ltp = safe_get(quote, 'ltp', 'iv', 'c')
                    ltq = safe_get(quote, 'ltq', 'v')
                    lo = safe_get(quote, 'lo', 'lowPrice', 'low')
                    h = safe_get(quote, 'h', 'highPrice', 'high')
                    lcl = safe_get(quote, 'lcl', 'lowerCircuit', 'lower_circuit')
                    ucl = safe_get(quote, 'ucl', 'upperCircuit', 'upper_circuit')
                    op = safe_get(quote, 'op', 'openingPrice', 'open')
                    c = safe_get(quote, 'c', 'ic', 'close')
                    oi = safe_get(quote, 'oi', 'openInterest', 'open_interest')
                    mul = safe_get(quote, 'mul', 'multiplier')
                    prec = safe_get(quote, 'prec', 'precision')
                    cng = safe_get(quote, 'cng', 'change')
                    nc = safe_get(quote, 'nc', 'changePct', 'nc', 'change_pct')
                    name = safe_get(quote, 'name', 'nm')
                    tk = safe_get(quote, 'tk', 'token', 'instrument_token')
                    e = safe_get(quote, 'e', 'exchange', 'exchange_segment')
                    ts = safe_get(quote, 'ts', 'tradingSymbol', 'trading_symbol')
                    
                    ltp_update_time = current_time_str if ltp != 'N/A' else 'N/A'

                    # Preserve previous OI when we either don't calculate OI this tick
                    # or new OI is not available; only overwrite when fresh OI is present
                    prev_oi, prev_oi_time = previous_oi_by_token.get(token, (None, 'N/A'))
                    if should_calc_oi and oi != 'N/A':
                        final_oi = oi
                        oi_update_time = current_time_str
                    else:
                        # carry forward previous if available
                        final_oi = prev_oi if prev_oi is not None and str(prev_oi) != 'N/A' else oi
                        oi_update_time = prev_oi_time if (prev_oi is not None and str(prev_oi) != 'N/A') else 'N/A'
                    
                    row_data = {
                        'token': token,
                        'pSymbol': token,
                        'pOptionType': token_info['option_type'],
                        'Strike Price': token_info['strike_price'],
                        'Expiry': token_info['expiry'],
                        'pScripRefKey': token_info['scrip_ref_key'],
                        'ltp': ltp,
                        'ltp_update_time': ltp_update_time,
                        'ltq': ltq,
                        'lo': lo,
                        'h': h,
                        'lcl': lcl,
                        'ucl': ucl,
                        'op': op,
                        'c': c,
                        'oi': final_oi,
                        'oi_update_time': oi_update_time,
                        'mul': mul,
                        'prec': prec,
                        'cng': cng,
                        'nc': nc,
                        'name': name if name != 'N/A' else 'N/A',
                        'tk': tk if tk != 'N/A' else token,
                        'e': e if e != 'N/A' else 'nse_fo',
                        'ts': ts if ts != 'N/A' else token_info['scrip_ref_key']
                    }
                    output_data.append(row_data)
                
                # Calculate total OI from filtered_tokens_data (source data) when needed
                # This matches the NIFTY calculation approach for consistency
                if should_calc_oi:
                    total_oi_ce = 0
                    total_oi_pe = 0
                    
                    for token_info in filtered_tokens_data:
                        token = str(token_info['token']).strip()
                        quote = all_quotes_data.get(token, {})
                        option_type = token_info['option_type']
                        
                        oi_value = safe_get(quote, 'oi', 'openInterest', 'open_interest')
                        
                        try:
                            if oi_value != 'N/A' and oi_value is not None:
                                oi_float = float(oi_value)
                                if option_type == 'CE':
                                    total_oi_ce += oi_float
                                elif option_type == 'PE':
                                    total_oi_pe += oi_float
                        except (ValueError, TypeError):
                            pass
                
                # Add or carry forward OI summary rows
                if should_calc_oi:
                    summary_ce = {
                        'token': 'SUMMARY_CE',
                        'pSymbol': 'TOTAL_CE_OI',
                        'pOptionType': 'CE',
                        'Strike Price': 'N/A',
                        'Expiry': filtered_tokens_data[0]['expiry'] if filtered_tokens_data else 'N/A',
                        'pScripRefKey': 'TOTAL_CE_OPEN_INTEREST',
                        'ltp': 'N/A', 'ltp_update_time': 'N/A', 'ltq': 'N/A',
                        'lo': 'N/A', 'h': 'N/A', 'lcl': 'N/A', 'ucl': 'N/A',
                        'op': 'N/A', 'c': 'N/A',
                        'oi': int(total_oi_ce),
                        'oi_update_time': current_time_str,
                        'mul': 'N/A', 'prec': 'N/A', 'cng': 'N/A', 'nc': 'N/A',
                        'name': 'Total CE OI',
                        'tk': 'TOTAL_CE_OI',
                        'e': 'nse_fo',
                        'ts': 'TOTAL_CALL_OPEN_INTEREST'
                    }
                    
                    summary_pe = {
                        'token': 'SUMMARY_PE',
                        'pSymbol': 'TOTAL_PE_OI',
                        'pOptionType': 'PE',
                        'Strike Price': 'N/A',
                        'Expiry': filtered_tokens_data[0]['expiry'] if filtered_tokens_data else 'N/A',
                        'pScripRefKey': 'TOTAL_PE_OPEN_INTEREST',
                        'ltp': 'N/A', 'ltp_update_time': 'N/A', 'ltq': 'N/A',
                        'lo': 'N/A', 'h': 'N/A', 'lcl': 'N/A', 'ucl': 'N/A',
                        'op': 'N/A', 'c': 'N/A',
                        'oi': int(total_oi_pe),
                        'oi_update_time': current_time_str,
                        'mul': 'N/A', 'prec': 'N/A', 'cng': 'N/A', 'nc': 'N/A',
                        'name': 'Total PE OI',
                        'tk': 'TOTAL_PE_OI',
                        'e': 'nse_fo',
                        'ts': 'TOTAL_PUT_OPEN_INTEREST'
                    }
                    
                    output_data.append(summary_ce)
                    output_data.append(summary_pe)
                    last_oi_calc_time = time.time()
                    
                    print(f"\n📊 OI Totals Calculated:")
                    print(f"   Total CE OI: {int(total_oi_ce):,}")
                    print(f"   Total PE OI: {int(total_oi_pe):,}")
                    print(f"   OI Ratio (CE/PE): {(total_oi_ce / total_oi_pe if total_oi_pe > 0 else 0):.2f}")
                else:
                    # Carry forward previous summaries if exist
                    prev_ce = previous_summary_oi.get('SUMMARY_CE')
                    prev_pe = previous_summary_oi.get('SUMMARY_PE')
                    if prev_ce:
                        output_data.append({
                            'token': 'SUMMARY_CE',
                            'pSymbol': 'TOTAL_CE_OI',
                            'pOptionType': 'CE',
                            'Strike Price': 'N/A',
                            'Expiry': filtered_tokens_data[0]['expiry'] if filtered_tokens_data else 'N/A',
                            'pScripRefKey': 'TOTAL_CE_OPEN_INTEREST',
                            'ltp': 'N/A', 'ltp_update_time': 'N/A', 'ltq': 'N/A',
                            'lo': 'N/A', 'h': 'N/A', 'lcl': 'N/A', 'ucl': 'N/A',
                            'op': 'N/A', 'c': 'N/A',
                            'oi': prev_ce[0],
                            'oi_update_time': prev_ce[1],
                            'mul': 'N/A', 'prec': 'N/A', 'cng': 'N/A', 'nc': 'N/A',
                            'name': 'Total CE OI',
                            'tk': 'TOTAL_CE_OI',
                            'e': 'nse_fo',
                            'ts': 'TOTAL_CALL_OPEN_INTEREST'
                        })
                    if prev_pe:
                        output_data.append({
                            'token': 'SUMMARY_PE',
                            'pSymbol': 'TOTAL_PE_OI',
                            'pOptionType': 'PE',
                            'Strike Price': 'N/A',
                            'Expiry': filtered_tokens_data[0]['expiry'] if filtered_tokens_data else 'N/A',
                            'pScripRefKey': 'TOTAL_PE_OPEN_INTEREST',
                            'ltp': 'N/A', 'ltp_update_time': 'N/A', 'ltq': 'N/A',
                            'lo': 'N/A', 'h': 'N/A', 'lcl': 'N/A', 'ucl': 'N/A',
                            'op': 'N/A', 'c': 'N/A',
                            'oi': prev_pe[0],
                            'oi_update_time': prev_pe[1],
                            'mul': 'N/A', 'prec': 'N/A', 'cng': 'N/A', 'nc': 'N/A',
                            'name': 'Total PE OI',
                            'tk': 'TOTAL_PE_OI',
                            'e': 'nse_fo',
                            'ts': 'TOTAL_PUT_OPEN_INTEREST'
                        })
                
                # Save to CSV with error handling for file locks
                df_output = pd.DataFrame(output_data)
                try:
                    df_output.to_csv(output_path, index=False, encoding='utf-8')
                    print(f"\n💾 Updated CSV: {output_path}")
                    print(f"   Total rows: {len(output_data)} (including 1 SENSEX row)")
                    print(f"   SENSEX CMP: ₹{current_sensex_cmp:.2f}")
                    print(f"   Tokens with data: {len(all_quotes_data)}/{len(all_tokens)}")
                except PermissionError:
                    print(f"\n⚠️  Could not save CSV (file may be open in Excel/editor)")
                    print(f"   Please close the file: {output_path}")
                    print(f"   Data fetched: {len(all_quotes_data)}/{len(all_tokens)} tokens")
                    print(f"   Total rows prepared: {len(output_data)}")
                except Exception as e:
                    print(f"\n⚠️  Error saving CSV: {e}")
                    print(f"   Data fetched: {len(all_quotes_data)}/{len(all_tokens)} tokens")
                
                # Wait for next iteration (WebSocket connections stay open and continue updating)
                print(f"\n⏳ Waiting {fetch_interval} seconds until next iteration...")
                print(f"   (WebSocket connections remain open and receiving live updates)")
                time.sleep(fetch_interval)
                
        except KeyboardInterrupt:
            print("\n\n🛑 Stopped by user")
            print(f"🔌 Closing WebSocket connections...")
            
            # Close all persistent WebSocket connections
            for batch_num, ws_conn, batch_tokens, batch_quotes in ws_connections:
                try:
                    ws_conn.close()
                    print(f"  ✓ Closed connection {batch_num}")
                except:
                    pass
            
            print(f"✅ Final data saved to: {output_path}")
            return output_path


def main():
    import argparse
    
    parser = argparse.ArgumentParser(description='Fetch live data for all Sensex option strikes')
    parser.add_argument('--input', '-i', type=str, default=None,
                       help='Input CSV file path (default: auto-find latest from outputs/)')
    parser.add_argument('--batch-size', '-b', type=int, default=50,
                       help='Number of tokens to fetch per batch (default: 50)')
    parser.add_argument('--continuous', '-c', action='store_true',
                       help='Enable continuous live data fetching mode')
    parser.add_argument('--fetch-interval', '-f', type=int, default=None,
                       help='Fetch interval in seconds (for continuous mode, default: 5)')
    parser.add_argument('--oi-interval', '-o', type=int, default=None,
                       help='OI calculation interval in seconds (for continuous mode, default: 10)')
    
    args = parser.parse_args()
    
    fetcher = AllStrikesDataFetcher()
    
    if args.continuous:
        fetcher.fetch_continuous_live_data(
            input_csv=args.input,
            fetch_interval=args.fetch_interval or 5,
            oi_calc_interval=args.oi_interval or 10
        )
    else:
        fetcher.fetch_all_strikes_data(
            input_csv=args.input,
            batch_size=args.batch_size,
            continuous_mode=False
        )


if __name__ == "__main__":
    main()

