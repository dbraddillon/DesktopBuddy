#pragma once
#include <Arduino.h>
#include <ArduinoJson.h>
#include <M5Unified.h>

// Desk dashboard: weather + home-lab health, pushed as one JSON line over USB
// serial by tools/dash-sender.ps1 while the PC's displays are on:
//   {"dash":{"temp":72,"hi":78,"lo":60,"cond":"Cloudy","health":0,"note":"all ok","ts":1790000000,"tz":-14400}}
// health: 0 ok, 1 warn, 2 bad.  ts/tz (epoch secs, UTC offset secs) set the RTC.
//
// The line doubles as a presence heartbeat: the sender stops when the displays
// are off, and main.cpp blanks the screen once the heartbeat goes stale. The
// Claude BLE link can't serve as presence — Claude Desktop keeps heartbeating
// with the monitors off.

struct DashState {
  bool     haveWx;
  int16_t  temp, hi, lo;
  char     cond[14];
  uint8_t  health;
  char     note[48];
  uint32_t lastMs;     // millis() of the last dash line; 0 = never received
};

static DashState _dash = {};
static bool      _dashRtcSet = false;

const uint32_t DASH_STALE_MS = 75000;   // sender interval is 15s

inline bool dashFresh() { return _dash.lastMs != 0 && (millis() - _dash.lastMs) < DASH_STALE_MS; }
inline bool dashStale() { return !dashFresh(); }
inline bool dashRtcSet() { return _dashRtcSet; }

inline void dashApply(JsonObjectConst d) {
  _dash.haveWx = d["temp"].is<int>();
  if (_dash.haveWx) {
    _dash.temp = d["temp"] | 0;
    _dash.hi   = d["hi"]   | _dash.temp;
    _dash.lo   = d["lo"]   | _dash.temp;
  }
  const char* c = d["cond"];
  strncpy(_dash.cond, c ? c : "", sizeof(_dash.cond) - 1);
  _dash.cond[sizeof(_dash.cond) - 1] = 0;
  _dash.health = d["health"] | 0;
  const char* n = d["note"];
  strncpy(_dash.note, n ? n : "", sizeof(_dash.note) - 1);
  _dash.note[sizeof(_dash.note) - 1] = 0;

  if (d["ts"].is<uint32_t>()) {
    time_t local = (time_t)d["ts"].as<uint32_t>() + (int32_t)(d["tz"] | 0);
    struct tm lt; gmtime_r(&local, &lt);
    m5::rtc_time_t tm = {};
    tm.hours = (int8_t)lt.tm_hour; tm.minutes = (int8_t)lt.tm_min; tm.seconds = (int8_t)lt.tm_sec;
    m5::rtc_date_t dt = {};
    dt.year = (int16_t)(lt.tm_year + 1900); dt.month = (int8_t)(lt.tm_mon + 1);
    dt.date = (int8_t)lt.tm_mday; dt.weekDay = (int8_t)lt.tm_wday;
    M5.Rtc.setTime(tm);
    M5.Rtc.setDate(dt);
    _dashRtcSet = true;
  }
  _dash.lastMs = millis();
}
