//+------------------------------------------------------------------+
//|                                          BrokerHistoryExport.mq5 |
//|                                         Copyright 2026, rpanchyk |
//|                                      https://github.com/rpanchyk |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, rpanchyk"
#property link      "https://github.com/rpanchyk"
#property version     "1.00"
#property description "Exports broker tick history and bars of any timeframe to CSV files."
#property description "Runs as a service: no chart is used. Progress is printed to the Experts journal."
#property service

//+------------------------------------------------------------------+
//| Enumerations used by inputs                                      |
//+------------------------------------------------------------------+
enum ENUM_EXPORT_TICKS
  {
   TICKS_ALL   = 0,  // All ticks
   TICKS_INFO  = 1,  // Bid/Ask changes only
   TICKS_TRADE = 2   // Last/Volume changes only (exchange symbols)
  };

enum ENUM_SPLIT_MODE
  {
   SPLIT_NONE  = 0,  // One file for the whole period
   SPLIT_YEAR  = 1,  // One file per year
   SPLIT_MONTH = 2,  // One file per month
   SPLIT_DAY   = 3   // One file per day
  };

enum ENUM_DELIMITER
  {
   DELIM_COMMA     = 0, // Comma ( , )
   DELIM_SEMICOLON = 1, // Semicolon ( ; )
   DELIM_TAB       = 2  // Tab
  };

enum ENUM_CRLF_TYPE
  {
   CRLF_WINDOWS = 0, // Windows (CR LF)
   CRLF_LINUX   = 1, // Linux / modern macOS (LF)
   CRLF_MACOS   = 2  // Classic Mac OS (CR)
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "What to export"
input string            InpSymbols             = "EURUSD";        // Symbols, comma separated (* = all Market Watch)
input bool              InpExportTicks         = true;            // Export ticks
input ENUM_EXPORT_TICKS InpTickType            = TICKS_ALL;       // Tick type
input string            InpBarTimeframes       = "";              // Bar timeframes, comma separated (e.g. M1,H1,D1)

input group "Period (broker server time)"
input datetime          InpDateFrom            = D'2026.11.01 00:00'; // Date from (inclusive)
input datetime          InpDateTo              = 0;               // Date to (exclusive, 1970.01.01 = now)

input group "Files"
input string            InpOutputFolder        = "HistoryExport"; // Output folder inside MQL5\Files
input bool              InpUseCommonFolder     = false;           // Use common folder of all terminals
input ENUM_SPLIT_MODE   InpTickSplitMode       = SPLIT_NONE;      // Split tick files by
input ENUM_SPLIT_MODE   InpBarSplitMode        = SPLIT_NONE;      // Split bar files by
input bool              InpSkipExisting        = true;            // Skip existing files (not for SPLIT_NONE)

input group "CSV format"
input ENUM_DELIMITER    InpDelimiter           = DELIM_COMMA;     // Delimiter
input string            InpTickColumns         = "datetime,bid,ask";                    // Tick columns (+ time_msc,last,volume,flags)
input string            InpBarColumns          = "datetime,open,high,low,close";        // Bar columns (+ tick_volume,spread,real_volume,time)
input bool              InpWriteHeader         = true;            // Write header row
input ENUM_CRLF_TYPE    InpCrlfType            = CRLF_WINDOWS;    // Line ending

input group "Loading"
input int               InpChunkHours          = 24;              // Tick request size, hours (1-168)
input int               InpMaxRetries          = 5;               // Max retries per request
input int               InpRetryDelayMs        = 1000;            // Delay between retries, ms
input bool              InpVerifyTicksWithM1   = true;            // Verify tick completeness with M1 bars
input int               InpConnectTimeoutSec   = 120;             // Wait for server connection, s (0-3600)
input int               InpProgressIntervalSec = 30;              // Progress interval, s (0 = off)

input group "History start"
input bool              InpProbeFirstTick      = true;            // Find the first tick since 2000.01.01
input bool              InpProbeFirstBar       = true;            // Find the first M1 bar since 2000.01.01

//+------------------------------------------------------------------+
//| Constants                                                        |
//+------------------------------------------------------------------+
#define RES_OK              0   // done (possibly with no data)
#define RES_ERROR           1   // this data type failed, continue with the next one
#define RES_STOP            2   // stopped by the user
#define RES_FATAL           3   // connection lost, the service must exit

#define FIRST_TICK_NOT_SEARCHED (-2)
#define HISTORY_PROBE_FROM  D'2000.01.01'  // the first tick and bar are searched from this date

#define CHECK_OK            0
#define CHECK_SUSPICIOUS    1
#define CHECK_UNVERIFIED    2

#define BARS_PER_CHUNK      100000
#define WRITE_BUFFER_CHARS  4194304
#define TICK_HISTORY_NOTE_SEC (7 * 86400)

// Tick columns
#define TC_DATETIME   0
#define TC_BID        1
#define TC_ASK        2
#define TC_TIME_MSC   3
#define TC_LAST       4
#define TC_VOLUME     5
#define TC_FLAGS      6

// Bar columns
#define BC_DATETIME    0
#define BC_OPEN        1
#define BC_HIGH        2
#define BC_LOW         3
#define BC_CLOSE       4
#define BC_TICK_VOLUME 5
#define BC_SPREAD      6
#define BC_REAL_VOLUME 7
#define BC_TIME        8

string          g_tickColNames[] = {"datetime", "bid", "ask", "time_msc", "last", "volume", "flags"};
string          g_barColNames[]  = {"datetime", "open", "high", "low", "close", "tick_volume", "spread", "real_volume", "time"};

string          g_tfNames[]  = {"M1", "M2", "M3", "M4", "M5", "M6", "M10", "M12", "M15", "M20", "M30",
                                "H1", "H2", "H3", "H4", "H6", "H8", "H12", "D1", "W1", "MN1"
                               };
ENUM_TIMEFRAMES g_tfValues[] = {PERIOD_M1, PERIOD_M2, PERIOD_M3, PERIOD_M4, PERIOD_M5, PERIOD_M6, PERIOD_M10,
                                PERIOD_M12, PERIOD_M15, PERIOD_M20, PERIOD_M30, PERIOD_H1, PERIOD_H2, PERIOD_H3,
                                PERIOD_H4, PERIOD_H6, PERIOD_H8, PERIOD_H12, PERIOD_D1, PERIOD_W1, PERIOD_MN1
                               };

//+------------------------------------------------------------------+
//| Per symbol / data type statistics                                |
//+------------------------------------------------------------------+
struct SStat
  {
   string            symbol;
   string            type;
   bool              is_ticks;
   int               files;
   int               skipped;
   long              rows;
   long              first_msc;
   long              last_msc;
   int               gaps;
   int               unverified;
   int               errors;
   string            note;
  };

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
string          g_prog = "BrokerHistoryExport";
int             g_common = 0;
datetime        g_from = 0;
datetime        g_to = 0;
string          g_delim = ",";
string          g_eol = "\r\n";
string          g_baseFolder = "";
int             g_tickCols[];
int             g_barCols[];
string          g_tickHeader = "";
string          g_barHeader = "";
int             g_tfIdx[];               // indexes into g_tfNames / g_tfValues, in user order
SStat           g_stats[];
ulong           g_lastProgress = 0;
long            g_dtCacheSec = -1;
string          g_dtCacheStr = "";

//+------------------------------------------------------------------+
//| CSV writer: buffered binary writes into <name>.csv.part,         |
//| renamed to <name>.csv on success                                 |
//+------------------------------------------------------------------+
class CCsvWriter
  {
private:
   int               m_handle;
   int               m_common;
   string            m_final;
   string            m_part;
   string            m_buf;
   uchar             m_bytes[];
   long              m_rows;
   bool              m_failed;
   int               m_lastError;

   bool              FlushBuffer(void);

public:
                     CCsvWriter(void) : m_handle(INVALID_HANDLE), m_common(0), m_rows(0), m_failed(false), m_lastError(0) {}
                    ~CCsvWriter(void) { Abort(); }

   bool              Open(const string final_path, const int common_flag, const string header);
   void              AddRow(const string &line);
   long              Rows(void) const { return m_rows; }
   bool              Failed(void) const { return m_failed; }
   int               LastError(void) const { return m_lastError; }
   string            PartPath(void) const { return m_part; }
   bool              Commit(void);
   void              Abort(void);
  };

//+------------------------------------------------------------------+
bool CCsvWriter::Open(const string final_path, const int common_flag, const string header)
  {
   m_final = final_path;
   m_part = final_path + ".part";
   m_common = common_flag;
   m_rows = 0;
   m_failed = false;
   m_lastError = 0;
   m_buf = "";
//--- no FILE_SHARE_WRITE: a .part written by another instance cannot be opened
   ResetLastError();
   m_handle = FileOpen(m_part, FILE_BIN | FILE_WRITE | FILE_SHARE_READ | m_common);
   if(m_handle == INVALID_HANDLE)
     {
      m_lastError = GetLastError();
      return false;
     }
   StringReserve(m_buf, WRITE_BUFFER_CHARS + 65536);
   if(header != "")
      StringAdd(m_buf, header);
   return true;
  }

//+------------------------------------------------------------------+
void CCsvWriter::AddRow(const string &line)
  {
   if(m_failed)
      return;
   StringAdd(m_buf, line);
   m_rows++;
   if(StringLen(m_buf) >= WRITE_BUFFER_CHARS)
      FlushBuffer();
  }

//+------------------------------------------------------------------+
bool CCsvWriter::FlushBuffer(void)
  {
   if(m_failed || m_handle == INVALID_HANDLE)
      return false;
   int len = StringLen(m_buf);
   if(len == 0)
      return true;
   int copied = StringToCharArray(m_buf, m_bytes, 0, len, CP_ACP);
   if(copied < len)
     {
      m_failed = true;
      m_lastError = GetLastError();
      return false;
     }
   ResetLastError();
   uint written = FileWriteArray(m_handle, m_bytes, 0, len);
   if(written != (uint)len)
     {
      m_failed = true;
      m_lastError = GetLastError();
      return false;
     }
   StringSetLength(m_buf, 0);
   return true;
  }

//+------------------------------------------------------------------+
bool CCsvWriter::Commit(void)
  {
   if(m_handle == INVALID_HANDLE)
      return false;
   if(!FlushBuffer())
     {
      Abort();
      return false;
     }
   FileClose(m_handle);
   m_handle = INVALID_HANDLE;
   m_buf = "";
   ArrayFree(m_bytes);
//--- no rows: no file
   if(m_rows == 0)
     {
      FileDelete(m_part, m_common);
      return true;
     }
   ResetLastError();
   if(!FileMove(m_part, m_common, m_final, m_common | FILE_REWRITE))
     {
      m_failed = true;
      m_lastError = GetLastError();
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
void CCsvWriter::Abort(void)
  {
   if(m_handle == INVALID_HANDLE)
      return;
   FileClose(m_handle);
   m_handle = INVALID_HANDLE;
   FileDelete(m_part, m_common);
   m_buf = "";
   ArrayFree(m_bytes);
  }

//+------------------------------------------------------------------+
//| Logging                                                          |
//+------------------------------------------------------------------+
void Log(const string sym, const string msg)
  {
   if(sym == "")
      PrintFormat("%s %s", g_prog, msg);
   else
      PrintFormat("%s [%s] %s", g_prog, sym, msg);
  }

//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
datetime DtMax(const datetime a, const datetime b) { return a > b ? a : b; }
datetime DtMin(const datetime a, const datetime b) { return a < b ? a : b; }

string Trim(const string s)
  {
   string r = s;
   StringTrimLeft(r);
   StringTrimRight(r);
   return r;
  }

//+------------------------------------------------------------------+
//| 12345678 -> "12 345 678"                                         |
//+------------------------------------------------------------------+
string FormatCount(const long value)
  {
   string digits = IntegerToString(value < 0 ? -value : value);
   string res = "";
   int len = StringLen(digits);
   for(int i = 0; i < len; i++)
     {
      if(i > 0 && (len - i) % 3 == 0)
         res += " ";
      res += StringSubstr(digits, i, 1);
     }
   return value < 0 ? "-" + res : res;
  }

//+------------------------------------------------------------------+
string FormatDuration(const long seconds)
  {
   long h = seconds / 3600;
   long m = (seconds % 3600) / 60;
   long s = seconds % 60;
   return StringFormat("%sh %02dm %02ds", IntegerToString(h), (int)m, (int)s);
  }

//+------------------------------------------------------------------+
string FormatDate(const datetime t)
  {
   return TimeToString(t, TIME_DATE);
  }

//+------------------------------------------------------------------+
string FormatDateTime(const datetime t)
  {
   return TimeToString(t, TIME_DATE | TIME_SECONDS);
  }

//+------------------------------------------------------------------+
//| "YYYY.MM.DD HH:MM:SS.mmm", the seconds part is cached            |
//+------------------------------------------------------------------+
string FormatTimeMsc(const long msc)
  {
   long sec = msc / 1000;
   if(sec != g_dtCacheSec)
     {
      g_dtCacheSec = sec;
      g_dtCacheStr = TimeToString((datetime)sec, TIME_DATE | TIME_SECONDS) + ".";
     }
   return g_dtCacheStr + IntegerToString(msc % 1000, 3, '0');
  }

//+------------------------------------------------------------------+
//| Volume without trailing zeros                                    |
//+------------------------------------------------------------------+
string FormatVolume(const double v)
  {
   if(v == 0.0)
      return "0";
   string s = DoubleToString(v, 8);
   int len = StringLen(s);
   while(len > 0 && StringGetCharacter(s, len - 1) == '0')
      len--;
   if(len > 0 && StringGetCharacter(s, len - 1) == '.')
      len--;
   return StringSubstr(s, 0, len);
  }

//+------------------------------------------------------------------+
string Date8(const datetime t)
  {
   MqlDateTime d;
   TimeToStruct(t, d);
   return StringFormat("%04d%02d%02d", d.year, d.mon, d.day);
  }

//+------------------------------------------------------------------+
string SplitName(const ENUM_SPLIT_MODE mode)
  {
   switch(mode)
     {
      case SPLIT_YEAR:
         return "YEAR";
      case SPLIT_MONTH:
         return "MONTH";
      case SPLIT_DAY:
         return "DAY";
     }
   return "NONE";
  }

//+------------------------------------------------------------------+
string TickTypeName(void)
  {
   switch(InpTickType)
     {
      case TICKS_INFO:
         return "INFO";
      case TICKS_TRADE:
         return "TRADE";
     }
   return "ALL";
  }

//+------------------------------------------------------------------+
uint TickCopyFlags(void)
  {
   switch(InpTickType)
     {
      case TICKS_INFO:
         return (uint)COPY_TICKS_INFO;
      case TICKS_TRADE:
         return (uint)COPY_TICKS_TRADE;
     }
   return (uint)COPY_TICKS_ALL;
  }

//+------------------------------------------------------------------+
//| Replace characters that are invalid in Windows file names        |
//+------------------------------------------------------------------+
string SafeFileName(const string s)
  {
   string r = s;
   string bad = "\\/:*?\"<>|";
   for(int i = 0; i < StringLen(bad); i++)
      StringReplace(r, StringSubstr(bad, i, 1), "_");
   return r;
  }

//+------------------------------------------------------------------+
string SymbolFolder(const string sym)
  {
   if(g_baseFolder == "")
      return SafeFileName(sym);
   return g_baseFolder + "\\" + SafeFileName(sym);
  }

//+------------------------------------------------------------------+
string FileRelPath(const string sym, const string type, const string label)
  {
   string safe = SafeFileName(sym);
   return SymbolFolder(sym) + "\\" + safe + "_" + type + "_" + label + ".csv";
  }

//+------------------------------------------------------------------+
//| Path relative to the output folder, for the journal              |
//+------------------------------------------------------------------+
string ShortPath(const string sym, const string type, const string label)
  {
   string safe = SafeFileName(sym);
   return safe + "\\" + safe + "_" + type + "_" + label + ".csv";
  }

//+------------------------------------------------------------------+
//| Calendar periods                                                 |
//+------------------------------------------------------------------+
datetime DayFloor(const datetime t)
  {
   return t - t % 86400;
  }

//+------------------------------------------------------------------+
datetime PeriodFloor(const datetime t, const ENUM_SPLIT_MODE mode)
  {
   MqlDateTime d;
   TimeToStruct(t, d);
   d.hour = 0;
   d.min = 0;
   d.sec = 0;
   if(mode == SPLIT_MONTH || mode == SPLIT_YEAR)
      d.day = 1;
   if(mode == SPLIT_YEAR)
      d.mon = 1;
   return StructToTime(d);
  }

//+------------------------------------------------------------------+
datetime NextMonth(const datetime t)
  {
   MqlDateTime d;
   TimeToStruct(t, d);
   d.day = 1;
   d.hour = 0;
   d.min = 0;
   d.sec = 0;
   d.mon++;
   if(d.mon > 12)
     {
      d.mon = 1;
      d.year++;
     }
   return StructToTime(d);
  }

//+------------------------------------------------------------------+
datetime PeriodNext(const datetime start, const ENUM_SPLIT_MODE mode)
  {
   if(mode == SPLIT_DAY)
      return start + 86400;
   if(mode == SPLIT_MONTH)
      return NextMonth(start);
   MqlDateTime d;
   TimeToStruct(start, d);
   d.year++;
   d.mon = 1;
   d.day = 1;
   d.hour = 0;
   d.min = 0;
   d.sec = 0;
   return StructToTime(d);
  }

//+------------------------------------------------------------------+
string PeriodLabel(const datetime start, const ENUM_SPLIT_MODE mode)
  {
   MqlDateTime d;
   TimeToStruct(start, d);
   if(mode == SPLIT_YEAR)
      return StringFormat("%04d", d.year);
   if(mode == SPLIT_MONTH)
      return StringFormat("%04d-%02d", d.year, d.mon);
   return StringFormat("%04d-%02d-%02d", d.year, d.mon, d.day);
  }

//+------------------------------------------------------------------+
//| Split [g_from, g_to) into file periods.                          |
//| starts[] are already clipped by g_from, ends[] by g_to.          |
//| forced[] = file must be rewritten even if it exists              |
//+------------------------------------------------------------------+
int BuildFilePeriods(const ENUM_SPLIT_MODE mode, datetime &starts[], datetime &ends[], bool &forced[], string &labels[])
  {
   ArrayResize(starts, 0);
   ArrayResize(ends, 0);
   ArrayResize(forced, 0);
   ArrayResize(labels, 0);
   if(mode == SPLIT_NONE)
     {
      ArrayResize(starts, 1);
      ArrayResize(ends, 1);
      ArrayResize(forced, 1);
      ArrayResize(labels, 1);
      starts[0] = g_from;
      ends[0] = g_to;
      forced[0] = true;
      labels[0] = Date8(g_from) + "_" + Date8(g_to);
      return 1;
     }
   datetime now = TimeTradeServer();
   int count = 0;
   datetime t = g_from;
   while(t < g_to)
     {
      datetime ps = PeriodFloor(t, mode);
      datetime nx = PeriodNext(ps, mode);
      datetime e = DtMin(nx, g_to);
      ArrayResize(starts, count + 1, 64);
      ArrayResize(ends, count + 1, 64);
      ArrayResize(forced, count + 1, 64);
      ArrayResize(labels, count + 1, 64);
      starts[count] = t;
      ends[count] = e;
      forced[count] = (ps < g_from || nx > g_to || nx > now);
      labels[count] = PeriodLabel(ps, mode);
      count++;
      t = e;
     }
   return count;
  }

//+------------------------------------------------------------------+
//| Bar close time (months have different length)                    |
//+------------------------------------------------------------------+
datetime BarClose(const datetime open_time, const ENUM_TIMEFRAMES tf)
  {
   if(tf == PERIOD_MN1)
      return NextMonth(open_time);
   return open_time + PeriodSeconds(tf);
  }

//+------------------------------------------------------------------+
//| Input parsing                                                    |
//+------------------------------------------------------------------+
bool ParseColumns(const string param, const string value, const string &names[], int &cols[], string &header)
  {
   ArrayResize(cols, 0);
   header = "";
   string parts[];
   int k = StringSplit(value, ',', parts);
   if(k <= 0 || Trim(value) == "")
     {
      Log("", StringFormat("ERROR: %s is empty", param));
      return false;
     }
   for(int i = 0; i < k; i++)
     {
      string name = Trim(parts[i]);
      StringToLower(name);
      if(name == "")
        {
         Log("", StringFormat("ERROR: %s = \"%s\": empty column name at position %d", param, value, i + 1));
         return false;
        }
      int id = -1;
      for(int j = 0; j < ArraySize(names); j++)
         if(names[j] == name)
           {
            id = j;
            break;
           }
      if(id < 0)
        {
         string allowed = "";
         for(int j = 0; j < ArraySize(names); j++)
            allowed += (j > 0 ? "," : "") + names[j];
         Log("", StringFormat("ERROR: %s: unknown column '%s' (allowed: %s)", param, Trim(parts[i]), allowed));
         return false;
        }
      for(int j = 0; j < ArraySize(cols); j++)
         if(cols[j] == id)
           {
            Log("", StringFormat("ERROR: %s: duplicate column '%s'", param, name));
            return false;
           }
      int n = ArraySize(cols);
      ArrayResize(cols, n + 1);
      cols[n] = id;
      header += (n > 0 ? g_delim : "") + name;
     }
   header += g_eol;
   return true;
  }

//+------------------------------------------------------------------+
bool ParseTimeframes(void)
  {
   ArrayResize(g_tfIdx, 0);
   string value = Trim(InpBarTimeframes);
   if(value == "")
      return true;
   string parts[];
   int k = StringSplit(value, ',', parts);
   for(int i = 0; i < k; i++)
     {
      string name = Trim(parts[i]);
      StringToUpper(name);
      if(name == "")
        {
         Log("", StringFormat("ERROR: InpBarTimeframes = \"%s\": empty timeframe at position %d", InpBarTimeframes, i + 1));
         return false;
        }
      int id = -1;
      for(int j = 0; j < ArraySize(g_tfNames); j++)
         if(g_tfNames[j] == name)
           {
            id = j;
            break;
           }
      if(id < 0)
        {
         Log("", StringFormat("ERROR: InpBarTimeframes: unknown timeframe '%s' (allowed: M1,M2,M3,M4,M5,M6,M10,M12,M15,M20,M30,H1,H2,H3,H4,H6,H8,H12,D1,W1,MN1)", Trim(parts[i])));
         return false;
        }
      for(int j = 0; j < ArraySize(g_tfIdx); j++)
         if(g_tfIdx[j] == id)
           {
            Log("", StringFormat("ERROR: InpBarTimeframes: duplicate timeframe '%s'", name));
            return false;
           }
      int n = ArraySize(g_tfIdx);
      ArrayResize(g_tfIdx, n + 1);
      g_tfIdx[n] = id;
     }
   return true;
  }

//+------------------------------------------------------------------+
bool CheckRange(const string name, const int value, const int min_value, const int max_value)
  {
   if(value >= min_value && value <= max_value)
      return true;
   Log("", StringFormat("ERROR: %s = %d is out of range %d..%d", name, value, min_value, max_value));
   return false;
  }

//+------------------------------------------------------------------+
//| Step 1 of preparation: everything that does not need connection  |
//+------------------------------------------------------------------+
bool ValidateInputs(void)
  {
   bool ok = true;
//--- formatting first: the headers depend on it
   switch(InpDelimiter)
     {
      case DELIM_SEMICOLON:
         g_delim = ";";
         break;
      case DELIM_TAB:
         g_delim = "\t";
         break;
      default:
         g_delim = ",";
     }
   switch(InpCrlfType)
     {
      case CRLF_LINUX:
         g_eol = "\n";
         break;
      case CRLF_MACOS:
         g_eol = "\r";
         break;
      default:
         g_eol = "\r\n";
     }
//---
   if(Trim(InpSymbols) == "")
     {
      Log("", "ERROR: InpSymbols is empty: specify symbols (e.g. EURUSD,GBPUSD) or * for all Market Watch symbols");
      ok = false;
     }
   if(!ParseTimeframes())
      ok = false;
   else
      if(!InpExportTicks && ArraySize(g_tfIdx) == 0)
        {
         Log("", "ERROR: nothing to export: InpExportTicks = false and InpBarTimeframes is empty");
         ok = false;
        }
   if(!CheckRange("InpChunkHours", InpChunkHours, 1, 168))
      ok = false;
   if(!CheckRange("InpMaxRetries", InpMaxRetries, 0, 100))
      ok = false;
   if(!CheckRange("InpRetryDelayMs", InpRetryDelayMs, 0, 60000))
      ok = false;
   if(!CheckRange("InpConnectTimeoutSec", InpConnectTimeoutSec, 0, 3600))
      ok = false;
   if(!CheckRange("InpProgressIntervalSec", InpProgressIntervalSec, 0, 86400))
      ok = false;
   if(InpExportTicks && !ParseColumns("InpTickColumns", InpTickColumns, g_tickColNames, g_tickCols, g_tickHeader))
      ok = false;
   if(ArraySize(g_tfIdx) > 0 && !ParseColumns("InpBarColumns", InpBarColumns, g_barColNames, g_barCols, g_barHeader))
      ok = false;
   if(!InpWriteHeader)
     {
      g_tickHeader = "";
      g_barHeader = "";
     }
//--- output folder: strip separators at both ends
   g_baseFolder = Trim(InpOutputFolder);
   StringReplace(g_baseFolder, "/", "\\");
   while(StringLen(g_baseFolder) > 0 && StringGetCharacter(g_baseFolder, 0) == '\\')
      g_baseFolder = StringSubstr(g_baseFolder, 1);
   while(StringLen(g_baseFolder) > 0 && StringGetCharacter(g_baseFolder, StringLen(g_baseFolder) - 1) == '\\')
      g_baseFolder = StringSubstr(g_baseFolder, 0, StringLen(g_baseFolder) - 1);
   return ok;
  }

//+------------------------------------------------------------------+
//| Symbols from InpSymbols, '*' = all Market Watch symbols          |
//+------------------------------------------------------------------+
void AddUnique(string &list[], const string s)
  {
   for(int i = 0; i < ArraySize(list); i++)
      if(list[i] == s)
         return;
   int n = ArraySize(list);
   ArrayResize(list, n + 1);
   list[n] = s;
  }

//+------------------------------------------------------------------+
int BuildSymbolList(string &symbols[], bool &has_star)
  {
   ArrayResize(symbols, 0);
   has_star = false;
   string requested[];
   string parts[];
   int k = StringSplit(InpSymbols, ',', parts);
   for(int i = 0; i < k; i++)
     {
      string s = Trim(parts[i]);
      if(s == "")
         continue;
      if(s == "*")
        {
         has_star = true;
         int total = SymbolsTotal(true);
         for(int j = 0; j < total; j++)
            AddUnique(requested, SymbolName(j, true));
        }
      else
         AddUnique(requested, s);
     }
   for(int i = 0; i < ArraySize(requested); i++)
     {
      ResetLastError();
      if(!SymbolSelect(requested[i], true))
        {
         Log(requested[i], StringFormat("WARNING: symbol not found or cannot be selected (error %d), skipped", GetLastError()));
         continue;
        }
      AddUnique(symbols, requested[i]);
     }
   return ArraySize(symbols);
  }

//+------------------------------------------------------------------+
//| Connection                                                       |
//+------------------------------------------------------------------+
bool IsConnected(void)
  {
   return TerminalInfoInteger(TERMINAL_CONNECTED) != 0;
  }

//+------------------------------------------------------------------+
bool WaitConnected(void)
  {
   if(IsConnected())
      return true;
   ulong start = GetTickCount64();
   while(!IsStopped() && GetTickCount64() - start < (ulong)InpConnectTimeoutSec * 1000)
     {
      Sleep(1000);
      if(IsConnected())
         return true;
     }
   return IsConnected();
  }

//+------------------------------------------------------------------+
bool EnsureConnected(const string sym)
  {
   if(IsConnected())
      return true;
   Log(sym, StringFormat("connection lost, waiting up to %d s", InpConnectTimeoutSec));
   if(WaitConnected())
     {
      Log(sym, "connection restored");
      return true;
     }
   if(!IsStopped())
      Log(sym, StringFormat("ERROR: no connection to the trade server for %d s", InpConnectTimeoutSec));
   return false;
  }

//+------------------------------------------------------------------+
int ConnectionResult(void)
  {
   return IsStopped() ? RES_STOP : RES_FATAL;
  }

//+------------------------------------------------------------------+
//| Progress line, not more often than InpProgressIntervalSec        |
//+------------------------------------------------------------------+
void Progress(const int si, const int stotal, const string sym, const string type,
              const datetime cur, const datetime type_start, const long rows)
  {
   if(InpProgressIntervalSec <= 0)
      return;
   ulong now = GetTickCount64();
   if(now - g_lastProgress < (ulong)InpProgressIntervalSec * 1000)
      return;
   g_lastProgress = now;
   int pct = 0;
   if(g_to > type_start)
      pct = (int)((long)(cur - type_start) * 100 / (long)(g_to - type_start));
   Log(sym, StringFormat("progress %d/%d %s %s (%d%%), %s rows", si + 1, stotal, type, FormatDate(cur), pct, FormatCount(rows)));
  }

//+------------------------------------------------------------------+
//| Line builders                                                    |
//+------------------------------------------------------------------+
void BuildTickLine(const MqlTick &t, const int digits, string &line)
  {
   StringSetLength(line, 0);
   int n = ArraySize(g_tickCols);
   for(int c = 0; c < n; c++)
     {
      if(c > 0)
         StringAdd(line, g_delim);
      switch(g_tickCols[c])
        {
         case TC_DATETIME:
            StringAdd(line, FormatTimeMsc(t.time_msc));
            break;
         case TC_BID:
            StringAdd(line, DoubleToString(t.bid, digits));
            break;
         case TC_ASK:
            StringAdd(line, DoubleToString(t.ask, digits));
            break;
         case TC_TIME_MSC:
            StringAdd(line, IntegerToString(t.time_msc));
            break;
         case TC_LAST:
            StringAdd(line, DoubleToString(t.last, digits));
            break;
         case TC_VOLUME:
            StringAdd(line, FormatVolume(t.volume_real));
            break;
         case TC_FLAGS:
            StringAdd(line, IntegerToString(t.flags));
            break;
        }
     }
   StringAdd(line, g_eol);
  }

//+------------------------------------------------------------------+
void BuildBarLine(const MqlRates &r, const int digits, string &line)
  {
   StringSetLength(line, 0);
   int n = ArraySize(g_barCols);
   for(int c = 0; c < n; c++)
     {
      if(c > 0)
         StringAdd(line, g_delim);
      switch(g_barCols[c])
        {
         case BC_DATETIME:
            StringAdd(line, TimeToString(r.time, TIME_DATE | TIME_SECONDS));
            break;
         case BC_OPEN:
            StringAdd(line, DoubleToString(r.open, digits));
            break;
         case BC_HIGH:
            StringAdd(line, DoubleToString(r.high, digits));
            break;
         case BC_LOW:
            StringAdd(line, DoubleToString(r.low, digits));
            break;
         case BC_CLOSE:
            StringAdd(line, DoubleToString(r.close, digits));
            break;
         case BC_TICK_VOLUME:
            StringAdd(line, IntegerToString(r.tick_volume));
            break;
         case BC_SPREAD:
            StringAdd(line, IntegerToString(r.spread));
            break;
         case BC_REAL_VOLUME:
            StringAdd(line, IntegerToString(r.real_volume));
            break;
         case BC_TIME:
            StringAdd(line, IntegerToString((long)r.time));
            break;
        }
     }
   StringAdd(line, g_eol);
  }

//+------------------------------------------------------------------+
//| Date property of a series, 0 if not available.                   |
//| Uses the bool form of SeriesInfoInteger, as the MQL5 sample      |
//| "Organizing Data Access" does                                    |
//+------------------------------------------------------------------+
datetime SeriesDate(const string sym, const ENUM_TIMEFRAMES tf, const ENUM_SERIES_INFO_INTEGER prop)
  {
   long value = 0;
   if(!SeriesInfoInteger(sym, tf, prop, value))
      return 0;
   return (datetime)value;
  }

//+------------------------------------------------------------------+
//| true if the terminal keeps fewer bars than the server has:       |
//| the local series is cut by "Max bars in chart"                   |
//+------------------------------------------------------------------+
bool LocalHistoryCut(const string sym, const ENUM_TIMEFRAMES tf)
  {
   long maxbars = TerminalInfoInteger(TERMINAL_MAXBARS);
   return (long)Bars(sym, tf) >= maxbars;
  }

//+------------------------------------------------------------------+
//| true if there are certainly no bars in [from, to]                |
//| (CopyRates returns -1 for such ranges)                           |
//+------------------------------------------------------------------+
bool RangeIsEmpty(const string sym, const ENUM_TIMEFRAMES tf, const datetime from, const datetime to)
  {
   if(!SeriesInfoInteger(sym, tf, SERIES_SYNCHRONIZED) || Bars(sym, tf, from, to) != 0)
      return false;
   datetime local_first = SeriesDate(sym, tf, SERIES_FIRSTDATE);
   datetime server_first = SeriesDate(sym, tf, SERIES_SERVER_FIRSTDATE);
//--- weekend / holiday inside the local history
   if(local_first > 0 && from >= local_first)
      return true;
//--- the whole range is older than the server history
   if(server_first > 0 && to < server_first)
      return true;
//--- server start is unknown: trust the local start if the terminal limit does not cut it
   if(server_first == 0 && local_first > 0 && to < local_first && !LocalHistoryCut(sym, tf))
      return true;
   return false;
  }

//+------------------------------------------------------------------+
//| Explanation for the journal when bars cannot be obtained         |
//+------------------------------------------------------------------+
string HistoryLimitHint(const string sym, const ENUM_TIMEFRAMES tf, const datetime from)
  {
   datetime local_first = SeriesDate(sym, tf, SERIES_FIRSTDATE);
   if(local_first > 0 && from < local_first && LocalHistoryCut(sym, tf))
      return StringFormat("; the terminal keeps only %s bars (\"Max bars in chart\"), local history starts at %s: set \"Max bars in chart\" to Unlimited and restart the terminal",
                          FormatCount(TerminalInfoInteger(TERMINAL_MAXBARS)), FormatDateTime(local_first));
   return "";
  }

//+------------------------------------------------------------------+
//| CopyRates [from, to] (both inclusive) with retries.              |
//| A range with certainly no bars is reported as 0 instead of -1.   |
//| Returns -1 if bars could not be obtained.                        |
//+------------------------------------------------------------------+
int CopyRatesSafe(const string sym, const ENUM_TIMEFRAMES tf, const datetime from, const datetime to,
                  MqlRates &rates[], const int retries, int &last_error)
  {
   last_error = 0;
   for(int a = 0; a <= retries; a++)
     {
      if(a > 0)
         Sleep(InpRetryDelayMs);
      if(IsStopped())
         return -1;
      ResetLastError();
      int n = CopyRates(sym, tf, from, to, rates);
      last_error = GetLastError();
      if(n >= 0)
         return n;
      if(RangeIsEmpty(sym, tf, from, to))
        {
         ArrayResize(rates, 0);
         return 0;
        }
     }
   return -1;
  }

//+------------------------------------------------------------------+
//| Completeness check of one tick chunk against M1 bars (5.4)       |
//+------------------------------------------------------------------+
int CheckTicksWithM1(const string sym, const MqlTick &ticks[], const int n,
                     const datetime cs, const datetime ce, const datetime verify_from, const bool quick,
                     datetime &gap_from, datetime &gap_to)
  {
   datetime vf = DtMax(cs, verify_from);
   vf -= vf % 60;
   if(vf >= ce)
      return CHECK_OK;
   MqlRates rates[];
   int err = 0;
   int m = CopyRatesSafe(sym, PERIOD_M1, vf, ce - 1, rates, quick ? 0 : InpMaxRetries, err);
   if(m < 0)
      return CHECK_UNVERIFIED;
   if(n == 0)
     {
      int i0 = -1, i1 = -1;
      for(int k = 0; k < m; k++)
         if(rates[k].tick_volume > 0 && rates[k].time >= vf)
           {
            if(i0 < 0)
               i0 = k;
            i1 = k;
           }
      if(i0 < 0)
         return CHECK_OK;
      gap_from = rates[i0].time;
      gap_to = DtMin(rates[i1].time + 60, ce);
      return CHECK_SUSPICIOUS;
     }
   datetime last_tick = ticks[n - 1].time;
   int i1 = -1;
   for(int k = 0; k < m; k++)
      if(rates[k].tick_volume > 0 && rates[k].time > last_tick + 60)
         i1 = k;
   if(i1 < 0)
      return CHECK_OK;
   gap_from = last_tick;
   gap_to = DtMin(rates[i1].time + 60, ce);
   return CHECK_SUSPICIOUS;
  }

//+------------------------------------------------------------------+
//| First tick not earlier than from (5.3).                          |
//| first_msc = -1 if there are no ticks                             |
//+------------------------------------------------------------------+
int FindFirstTick(const string sym, const uint flags, const datetime from, long &first_msc)
  {
   first_msc = -1;
   MqlTick t[];
   int err = 0;
   for(int a = 0; a <= InpMaxRetries; a++)
     {
      if(a > 0)
         Sleep(InpRetryDelayMs);
      if(IsStopped())
         return RES_STOP;
      if(!EnsureConnected(sym))
         return ConnectionResult();
      ResetLastError();
      //--- from = 0 means "the latest ticks" for CopyTicks, so 1970.01.01 is sent as 1 ms
      ulong from_msc = (from > 0) ? (ulong)from * 1000 : 1;
      int n = CopyTicks(sym, t, flags, from_msc, 1);
      err = GetLastError();
      if(n > 0)
        {
         first_msc = t[0].time_msc;
         return RES_OK;
        }
     }
   if(err != 0)
      Log(sym, StringFormat("TICKS: first tick not found (error %d)", err));
   return RES_OK;
  }

//+------------------------------------------------------------------+
//| Load one tick chunk [cs, ce) with retries and verification       |
//+------------------------------------------------------------------+
int LoadTickChunk(const string sym, const uint flags, const datetime cs, const datetime ce,
                  const datetime verify_from, const bool verify, const bool m1_quick,
                  MqlTick &ticks[], int &n, bool &gap, datetime &gap_from, datetime &gap_to, bool &unverified)
  {
   n = 0;
   gap = false;
   unverified = false;
   int err = 0;
   for(int a = 0; a <= InpMaxRetries; a++)
     {
      if(a > 0)
         Sleep(InpRetryDelayMs);
      if(IsStopped())
         return RES_STOP;
      if(!EnsureConnected(sym))
         return ConnectionResult();
      bool last = (a == InpMaxRetries);
      ResetLastError();
      n = CopyTicksRange(sym, ticks, flags, (ulong)cs * 1000, (ulong)ce * 1000 - 1);
      err = GetLastError();
      if(err == ERR_NOT_ENOUGH_MEMORY)
        {
         Log(sym, StringFormat("ERROR: not enough memory for ticks %s .. %s, decrease InpChunkHours (now %d)",
                               FormatDateTime(cs), FormatDateTime(ce), InpChunkHours));
         n = 0;
         return RES_ERROR;
        }
      if(n < 0 || err != 0)
        {
         if(!last)
            continue;
         if(n <= 0)
           {
            Log(sym, StringFormat("ERROR: TICKS %s .. %s: no data after %d retries (error %d)",
                                  FormatDateTime(cs), FormatDateTime(ce), InpMaxRetries, err));
            n = 0;
            return RES_ERROR;
           }
        }
      if(!verify)
         return RES_OK;
      int check = CheckTicksWithM1(sym, ticks, n, cs, ce, verify_from, m1_quick, gap_from, gap_to);
      if(check == CHECK_OK)
         return RES_OK;
      if(check == CHECK_UNVERIFIED)
        {
         unverified = true;
         return RES_OK;
        }
      if(last)
        {
         gap = true;
         return RES_OK;
        }
     }
   return RES_OK;
  }

//+------------------------------------------------------------------+
//| Load one bar chunk [cs, ce) with retries                         |
//+------------------------------------------------------------------+
int LoadBarChunk(const string sym, const ENUM_TIMEFRAMES tf, const string type,
                 const datetime cs, const datetime ce, MqlRates &rates[], int &n)
  {
   n = 0;
   int err = 0;
   for(int a = 0; a <= InpMaxRetries; a++)
     {
      if(a > 0)
         Sleep(InpRetryDelayMs);
      if(IsStopped())
         return RES_STOP;
      if(!EnsureConnected(sym))
         return ConnectionResult();
      bool last = (a == InpMaxRetries);
      n = CopyRatesSafe(sym, tf, cs, ce - 1, rates, 0, err);
      if(IsStopped())
         return RES_STOP;
      if(n < 0)
        {
         if(!last)
            continue;
         Log(sym, StringFormat("ERROR: %s %s .. %s: no data after %d retries (error %d)%s",
                               type, FormatDateTime(cs), FormatDateTime(ce), InpMaxRetries, err,
                               HistoryLimitHint(sym, tf, cs)));
         n = 0;
         return RES_ERROR;
        }
      if(!SeriesInfoInteger(sym, tf, SERIES_SYNCHRONIZED) && !last)
         continue;
      return RES_OK;
     }
   return RES_OK;
  }

//+------------------------------------------------------------------+
//| Statistics                                                       |
//+------------------------------------------------------------------+
int AddStat(const string sym, const string type, const bool is_ticks)
  {
   int i = ArraySize(g_stats);
   ArrayResize(g_stats, i + 1);
   g_stats[i].symbol = sym;
   g_stats[i].type = type;
   g_stats[i].is_ticks = is_ticks;
   g_stats[i].files = 0;
   g_stats[i].skipped = 0;
   g_stats[i].rows = 0;
   g_stats[i].first_msc = -1;
   g_stats[i].last_msc = -1;
   g_stats[i].gaps = 0;
   g_stats[i].unverified = 0;
   g_stats[i].errors = 0;
   g_stats[i].note = "";
   return i;
  }

//+------------------------------------------------------------------+
string FormatStatTime(const long msc, const bool is_ticks)
  {
   if(msc < 0)
      return "-";
   if(is_ticks)
      return FormatTimeMsc(msc);
   return FormatDateTime((datetime)(msc / 1000));
  }

//+------------------------------------------------------------------+
void MergeRange(SStat &st, const long first_msc, const long last_msc)
  {
   if(first_msc < 0)
      return;
   if(st.first_msc < 0 || first_msc < st.first_msc)
      st.first_msc = first_msc;
   if(last_msc > st.last_msc)
      st.last_msc = last_msc;
  }

//+------------------------------------------------------------------+
//| Common part: skip check and file opening                         |
//| Returns: 1 = opened, 0 = skipped, -1 = error                     |
//+------------------------------------------------------------------+
int OpenPeriodFile(CCsvWriter &w, const string sym, const string type, const string label,
                   const bool forced, const ENUM_SPLIT_MODE mode, const string header, SStat &st)
  {
   string rel = FileRelPath(sym, type, label);
   if(InpSkipExisting && mode != SPLIT_NONE && !forced && FileIsExist(rel, g_common))
     {
      Log(sym, StringFormat("%s %s: skipped (exists)", type, label));
      st.skipped++;
      return 0;
     }
   if(!w.Open(rel, g_common, header))
     {
      int err = w.LastError();
      Log(sym, StringFormat("ERROR: %s %s: cannot open %s.part (error %d); it may be written by another instance or another program",
                            type, label, ShortPath(sym, type, label), err));
      st.errors++;
      return -1;
     }
   return 1;
  }

//+------------------------------------------------------------------+
//| Common part: commit and file summary                             |
//+------------------------------------------------------------------+
bool ClosePeriodFile(CCsvWriter &w, const string sym, const string type, const string label, const bool is_ticks,
                     const long f_first, const long f_last, const int f_gaps, const int f_unverified, SStat &st)
  {
   long rows = w.Rows();
   if(!w.Commit())
     {
      Log(sym, StringFormat("ERROR: %s %s: cannot write or rename the file (error %d)",
                            type, label, w.LastError()));
      st.errors++;
      return false;
     }
   if(rows == 0)
     {
      Log(sym, StringFormat("%s %s: no data, file not created", type, label));
      return true;
     }
   st.files++;
   st.rows += rows;
   st.gaps += f_gaps;
   st.unverified += f_unverified;
   MergeRange(st, f_first, f_last);
   string extra = is_ticks ? StringFormat(", gaps=%d", f_gaps) : "";
   if(f_unverified > 0)
      extra += StringFormat(", unverified=%d", f_unverified);
   Log(sym, StringFormat("%s %s: %s rows, %s .. %s%s -> %s", type, label, FormatCount(rows),
                         FormatStatTime(f_first, is_ticks), FormatStatTime(f_last, is_ticks), extra,
                         ShortPath(sym, type, label)));
   return true;
  }

//+------------------------------------------------------------------+
//| Journal line about the first tick of the period                  |
//+------------------------------------------------------------------+
void LogFirstTick(const string sym, const long first_msc)
  {
   if(first_msc < 0 || first_msc >= (long)g_to * 1000)
     {
      Log(sym, "TICKS: no ticks in the requested period");
      return;
     }
   datetime first_sec = (datetime)(first_msc / 1000);
   if(first_sec - g_from > TICK_HISTORY_NOTE_SEC)
      Log(sym, StringFormat("TICKS: tick history starts at %s, requested %s", FormatTimeMsc(first_msc), FormatDate(g_from)));
   else
      Log(sym, StringFormat("TICKS: first tick at %s", FormatTimeMsc(first_msc)));
  }

//+------------------------------------------------------------------+
//| First M1 bar since HISTORY_PROBE_FROM. The first request can     |
//| download the history of the symbol and take minutes; later it is |
//| cached. The terminal gives at most "Max bars in chart" M1 bars:  |
//| cut = true if the answer is cut by this limit, then first_bar is |
//| the first bar inside the limit, not the start of the history.    |
//| first_bar = 0 if no bar was obtained                             |
//+------------------------------------------------------------------+
int ProbeFirstBar(const string sym, datetime &first_bar, bool &cut)
  {
   first_bar = 0;
   cut = false;
   datetime times[];
   int err = 0;
   for(int a = 0; a <= InpMaxRetries; a++)
     {
      if(a > 0)
         Sleep(InpRetryDelayMs);
      if(IsStopped())
         return RES_STOP;
      if(!EnsureConnected(sym))
         return ConnectionResult();
      ResetLastError();
      int n = CopyTime(sym, PERIOD_M1, HISTORY_PROBE_FROM, TimeTradeServer(), times);
      err = GetLastError();
      if(IsStopped())
         return RES_STOP;
      if(n > 0)
        {
         first_bar = times[0];
         cut = ((long)n >= TerminalInfoInteger(TERMINAL_MAXBARS));
         return RES_OK;
        }
     }
   Log(sym, StringFormat("WARNING: history: first bar since %s not found (error %d)", FormatDate(HISTORY_PROBE_FROM), err));
   return RES_OK;
  }

//+------------------------------------------------------------------+
//| History depth of one symbol, printed at the start:               |
//| first tick and first M1 bar since HISTORY_PROBE_FROM (only the   |
//| searches that are enabled and needed) and the first tick of the  |
//| requested period (if ticks are exported).                        |
//| bars_start = start of the bar history, 0 if it is earlier than   |
//| HISTORY_PROBE_FROM or unknown                                    |
//+------------------------------------------------------------------+
int LogHistoryInfo(const string sym, long &first_tick_msc, datetime &bars_start)
  {
   first_tick_msc = FIRST_TICK_NOT_SEARCHED;
   bars_start = 0;
   uint flags = TickCopyFlags();
   int res = RES_OK;
//--- first tick since HISTORY_PROBE_FROM (fast: a single tick is requested).
//--- Only when ticks are exported and InpProbeFirstTick = true
   long probe_tick = FIRST_TICK_NOT_SEARCHED;
   if(InpExportTicks && InpProbeFirstTick)
     {
      res = FindFirstTick(sym, flags, HISTORY_PROBE_FROM, probe_tick);
      if(res != RES_OK)
         return res;
      if(probe_tick >= 0)
         Log(sym, StringFormat("history: first tick since %s: %s", FormatDate(HISTORY_PROBE_FROM), FormatTimeMsc(probe_tick)));
      else
         Log(sym, StringFormat("history: no ticks since %s", FormatDate(HISTORY_PROBE_FROM)));
     }
//--- first bar since HISTORY_PROBE_FROM (slow on the first run)
   datetime first_bar = 0;
   bool cut = false;
//--- only when bars are exported and InpProbeFirstBar = true
   if(ArraySize(g_tfIdx) > 0 && InpProbeFirstBar)
     {
      res = ProbeFirstBar(sym, first_bar, cut);
      if(res != RES_OK)
         return res;
     }
   if(first_bar > 0)
     {
      if(cut)
         //--- the terminal limit, not the history start: older M1 bars can exist
         Log(sym, StringFormat("history: first M1 bar since %s: %s (cut by \"Max bars in chart\" = %s; older bars can exist)",
                               FormatDate(HISTORY_PROBE_FROM), FormatDateTime(first_bar), FormatCount(TerminalInfoInteger(TERMINAL_MAXBARS))));
      else
         //--- a bar in the first week of the probe period: the history may be older
         if(first_bar - HISTORY_PROBE_FROM > TICK_HISTORY_NOTE_SEC)
           {
            bars_start = first_bar;
            Log(sym, StringFormat("history: first M1 bar since %s: %s", FormatDate(HISTORY_PROBE_FROM), FormatDateTime(first_bar)));
           }
         else
            Log(sym, StringFormat("history: first M1 bar since %s: %s (the history can be older)", FormatDate(HISTORY_PROBE_FROM), FormatDateTime(first_bar)));
     }
//--- first tick of the requested period: reuse the probe if possible
   if(!InpExportTicks)
      return RES_OK;
   long msc = probe_tick;
   if(probe_tick == FIRST_TICK_NOT_SEARCHED || (probe_tick >= 0 && probe_tick < (long)g_from * 1000))
     {
      res = FindFirstTick(sym, flags, g_from, msc);
      if(res != RES_OK)
         return res;
     }
   first_tick_msc = msc;
   LogFirstTick(sym, msc);
   return RES_OK;
  }

//+------------------------------------------------------------------+
//| Ticks of one symbol                                              |
//+------------------------------------------------------------------+
int ExportTicks(const int si, const int stotal, const string sym, const int digits, const long known_first_msc, SStat &st)
  {
   const string type = "TICKS";
   uint flags = TickCopyFlags();
//--- first available tick (normally already found at the start)
   long first_msc = known_first_msc;
   int res = RES_OK;
   if(first_msc == FIRST_TICK_NOT_SEARCHED)
     {
      res = FindFirstTick(sym, flags, g_from, first_msc);
      if(res != RES_OK)
         return res;
      LogFirstTick(sym, first_msc);
     }
   if(first_msc < 0 || first_msc >= (long)g_to * 1000)
     {
      st.note = "no data";
      return RES_OK;
     }
   datetime first_sec = (datetime)(first_msc / 1000);
   datetime eff_start = DtMax(g_from, DayFloor(first_sec));
   bool verify = InpVerifyTicksWithM1 && InpTickType != TICKS_TRADE;
//--- files
   datetime ps[], pe[];
   bool forced[];
   string labels[];
   int pcount = BuildFilePeriods(InpTickSplitMode, ps, pe, forced, labels);
   long chunk_sec = (long)InpChunkHours * 3600;
   long type_rows = 0;
   MqlTick ticks[];
   string line = "";
   StringReserve(line, 256);
   for(int p = 0; p < pcount; p++)
     {
      if(pe[p] <= eff_start)
         continue;
      if(IsStopped())
         return RES_STOP;
      CCsvWriter w;
      int op = OpenPeriodFile(w, sym, type, labels[p], forced[p], InpTickSplitMode, g_tickHeader, st);
      if(op < 0)
         return RES_ERROR;
      if(op == 0)
         continue;
      long f_first = -1, f_last = -1;
      int f_gaps = 0, f_unverified = 0;
      bool m1_quick = false;
      datetime cs = DtMax(ps[p], eff_start);
      while(cs < pe[p])
        {
         datetime ce = ((long)(pe[p] - cs) > chunk_sec) ? (datetime)(cs + chunk_sec) : pe[p];
         if(IsStopped())
           {
            w.Abort();
            return RES_STOP;
           }
         Progress(si, stotal, sym, type, cs, eff_start, type_rows);
         int n = 0;
         bool gap = false, unverified = false;
         datetime gap_from = 0, gap_to = 0;
         res = LoadTickChunk(sym, flags, cs, ce, first_sec, verify, m1_quick, ticks, n, gap, gap_from, gap_to, unverified);
         if(res != RES_OK)
           {
            w.Abort();
            if(res == RES_ERROR)
              {
               st.errors++;
               Log(sym, StringFormat("ERROR: %s %s is incomplete and was not saved", type, labels[p]));
              }
            return res;
           }
         if(gap)
           {
            f_gaps++;
            Log(sym, StringFormat("GAP %s %s .. %s: M1 bars exist, no ticks after %d retries",
                                  type, TimeToString(gap_from, TIME_DATE | TIME_MINUTES),
                                  TimeToString(gap_to, TIME_DATE | TIME_MINUTES), InpMaxRetries));
           }
         if(unverified)
           {
            if(f_unverified == 0)
               Log(sym, StringFormat("WARNING: %s %s: M1 bars are not available, tick completeness is not verified (check \"Max bars in chart\")",
                                     type, labels[p]));
            f_unverified++;
            m1_quick = true;
           }
         for(int k = 0; k < n; k++)
           {
            BuildTickLine(ticks[k], digits, line);
            w.AddRow(line);
           }
         if(w.Failed())
           {
            Log(sym, StringFormat("ERROR: %s %s: write error %d (disk full?)", type, labels[p], w.LastError()));
            w.Abort();
            st.errors++;
            return RES_ERROR;
           }
         if(n > 0)
           {
            if(f_first < 0)
               f_first = ticks[0].time_msc;
            f_last = ticks[n - 1].time_msc;
            type_rows += n;
           }
         cs = ce;
        }
      if(!ClosePeriodFile(w, sym, type, labels[p], true, f_first, f_last, f_gaps, f_unverified, st))
         return RES_ERROR;
     }
   ArrayFree(ticks);
   return RES_OK;
  }

//+------------------------------------------------------------------+
//| Bars of one symbol and timeframe                                 |
//+------------------------------------------------------------------+
int ExportBars(const int si, const int stotal, const string sym, const int digits,
               const ENUM_TIMEFRAMES tf, const string type, const datetime bars_start, SStat &st)
  {
//--- history depth: bars_start comes from the probe at the start (LogHistoryInfo).
//--- SERIES_SERVER_FIRSTDATE is 0 in services, but is used if a terminal gives it
   datetime server_first = SeriesDate(sym, tf, SERIES_SERVER_FIRSTDATE);
   if(server_first == 0)
      server_first = bars_start;
   datetime eff_start = g_from;
   if(server_first > 0 && server_first > g_from)
     {
      Log(sym, StringFormat("%s: bar history starts at %s, requested %s", type, FormatDate(server_first), FormatDate(g_from)));
      eff_start = server_first;
     }
   if(eff_start >= g_to)
     {
      Log(sym, StringFormat("%s: no bars in the requested period", type));
      st.note = "no data";
      return RES_OK;
     }
//--- files
   datetime ps[], pe[];
   bool forced[];
   string labels[];
   int pcount = BuildFilePeriods(InpBarSplitMode, ps, pe, forced, labels);
   long chunk_sec = (long)BARS_PER_CHUNK * PeriodSeconds(tf);
   long type_rows = 0;
   MqlRates rates[];
   string line = "";
   StringReserve(line, 256);
   for(int p = 0; p < pcount; p++)
     {
      if(pe[p] <= eff_start)
         continue;
      if(IsStopped())
         return RES_STOP;
      CCsvWriter w;
      int op = OpenPeriodFile(w, sym, type, labels[p], forced[p], InpBarSplitMode, g_barHeader, st);
      if(op < 0)
         return RES_ERROR;
      if(op == 0)
         continue;
      long f_first = -1, f_last = -1;
      datetime cs = DtMax(ps[p], eff_start);
      while(cs < pe[p])
        {
         datetime ce = ((long)(pe[p] - cs) > chunk_sec) ? (datetime)(cs + chunk_sec) : pe[p];
         if(IsStopped())
           {
            w.Abort();
            return RES_STOP;
           }
         Progress(si, stotal, sym, type, cs, eff_start, type_rows);
         int n = 0;
         int res = LoadBarChunk(sym, tf, type, cs, ce, rates, n);
         if(res != RES_OK)
           {
            w.Abort();
            if(res == RES_ERROR)
              {
               st.errors++;
               Log(sym, StringFormat("ERROR: %s %s is incomplete and was not saved", type, labels[p]));
              }
            return res;
           }
         datetime now = TimeTradeServer();
         for(int k = 0; k < n; k++)
           {
            if(rates[k].time < cs || rates[k].time >= ce)
               continue;
            if(BarClose(rates[k].time, tf) > now)
               continue;               // the bar is still forming
            BuildBarLine(rates[k], digits, line);
            w.AddRow(line);
            if(f_first < 0)
               f_first = (long)rates[k].time * 1000;
            f_last = (long)rates[k].time * 1000;
            type_rows++;
           }
         if(w.Failed())
           {
            Log(sym, StringFormat("ERROR: %s %s: write error %d (disk full?)", type, labels[p], w.LastError()));
            w.Abort();
            st.errors++;
            return RES_ERROR;
           }
         cs = ce;
        }
      if(!ClosePeriodFile(w, sym, type, labels[p], false, f_first, f_last, 0, 0, st))
         return RES_ERROR;
     }
   ArrayFree(rates);
   return RES_OK;
  }

//+------------------------------------------------------------------+
//| Final summary                                                    |
//+------------------------------------------------------------------+
void PrintSummary(const string status, const ulong started)
  {
   Log("", "summary:");
   Log("", StringFormat("%-14s %-6s %6s %8s %14s %-23s %-23s %6s %10s %6s",
                        "symbol", "type", "files", "skipped", "rows", "first", "last", "gaps", "unverified", "errors"));
   long total_rows = 0;
   int total_files = 0, total_gaps = 0, total_errors = 0;
   for(int i = 0; i < ArraySize(g_stats); i++)
     {
      SStat st = g_stats[i];
      Log("", StringFormat("%-14s %-6s %6d %8d %14s %-23s %-23s %6s %10s %6d%s",
                           st.symbol, st.type, st.files, st.skipped, FormatCount(st.rows),
                           FormatStatTime(st.first_msc, st.is_ticks), FormatStatTime(st.last_msc, st.is_ticks),
                           st.is_ticks ? IntegerToString(st.gaps) : "-",
                           st.is_ticks ? IntegerToString(st.unverified) : "-",
                           st.errors, st.note != "" ? "  (" + st.note + ")" : ""));
      total_rows += st.rows;
      total_files += st.files;
      total_gaps += st.gaps;
      total_errors += st.errors;
     }
   long elapsed = (long)((GetTickCount64() - started) / 1000);
   Log("", StringFormat("%s: %d files, %s rows, gaps=%d, errors=%d, elapsed %s",
                        status, total_files, FormatCount(total_rows), total_gaps, total_errors, FormatDuration(elapsed)));
  }

//+------------------------------------------------------------------+
//| Warnings of step 5.1.5                                           |
//+------------------------------------------------------------------+
void PrintStartWarnings(const bool has_star)
  {
   if(has_star && InpExportTicks)
      Log("", "WARNING: InpSymbols = * with ticks: the amount of data is multiplied by the number of Market Watch symbols");
   if(InpSkipExisting && ((InpExportTicks && InpTickSplitMode == SPLIT_NONE) || (ArraySize(g_tfIdx) > 0 && InpBarSplitMode == SPLIT_NONE)))
      Log("", "WARNING: InpSkipExisting is ignored for SPLIT_NONE: such files are always written again");
   long maxbars = TerminalInfoInteger(TERMINAL_MAXBARS);
   long span = (long)(TimeTradeServer() - g_from);
   bool m1_listed = false;
   for(int i = 0; i < ArraySize(g_tfIdx); i++)
     {
      ENUM_TIMEFRAMES tf = g_tfValues[g_tfIdx[i]];
      if(tf == PERIOD_M1)
         m1_listed = true;
      long need = span / PeriodSeconds(tf);
      if(PeriodSeconds(tf) < 86400)
         need = need * 5 / 7;          // roughly no bars on weekends
      if(need > maxbars)
         Log("", StringFormat("WARNING: %s: the period needs about %s bars, \"Max bars in chart\" is %s; older bars may be unavailable (set it to Unlimited and restart the terminal)",
                              g_tfNames[g_tfIdx[i]], FormatCount(need), FormatCount(maxbars)));
     }
   if(InpExportTicks && InpVerifyTicksWithM1 && InpTickType != TICKS_TRADE && !m1_listed)
     {
      long need = span / 60 * 5 / 7;
      if(need > maxbars)
         Log("", StringFormat("WARNING: tick verification needs about %s M1 bars, \"Max bars in chart\" is %s; older ticks will be unverified",
                              FormatCount(need), FormatCount(maxbars)));
     }
  }

//+------------------------------------------------------------------+
//| Service entry point                                              |
//+------------------------------------------------------------------+
void OnStart()
  {
   ulong started = GetTickCount64();
   g_prog = MQLInfoString(MQL_PROGRAM_NAME);
   g_common = InpUseCommonFolder ? FILE_COMMON : 0;
   ArrayResize(g_stats, 0);
//--- 1. inputs
   if(!ValidateInputs())
     {
      Log("", "invalid inputs, export not started");
      return;
     }
//--- 2. connection
   if(!IsConnected())
      Log("", StringFormat("waiting for connection to the trade server (up to %d s)", InpConnectTimeoutSec));
   if(!WaitConnected())
     {
      if(IsStopped())
         Log("", "stopped before export");
      else
         Log("", StringFormat("ERROR: no connection to the trade server after %d s, export not started", InpConnectTimeoutSec));
      return;
     }
//--- 3. period
   g_from = InpDateFrom;
   g_to = (InpDateTo == 0) ? TimeTradeServer() : InpDateTo;
   if(g_from >= g_to)
     {
      Log("", StringFormat("ERROR: InpDateFrom (%s) must be earlier than the end of the period (%s)",
                           FormatDateTime(g_from), FormatDateTime(g_to)));
      return;
     }
//--- 4. symbols
   string symbols[];
   bool has_star = false;
   int stotal = BuildSymbolList(symbols, has_star);
   if(stotal == 0)
     {
      Log("", StringFormat("ERROR: no valid symbols in InpSymbols = \"%s\"", InpSymbols));
      return;
     }
//--- start line
   string tf_list = "";
   for(int i = 0; i < ArraySize(g_tfIdx); i++)
      tf_list += (i > 0 ? "," : "") + g_tfNames[g_tfIdx[i]];
   string sym_list = "";
   for(int i = 0; i < stotal; i++)
      sym_list += (i > 0 ? "," : "") + symbols[i];
   Log("", StringFormat("start: symbols=%s, ticks=%s, bars=%s, %s .. %s, split ticks=%s bars=%s, folder=%s%s",
                        sym_list, InpExportTicks ? TickTypeName() : "off", tf_list == "" ? "off" : tf_list,
                        FormatDateTime(g_from), FormatDateTime(g_to),
                        SplitName(InpTickSplitMode), SplitName(InpBarSplitMode),
                        g_baseFolder == "" ? "." : g_baseFolder, InpUseCommonFolder ? " (common)" : ""));
//--- 5. warnings
   PrintStartWarnings(has_star);
//--- 6. folders
   if(g_baseFolder != "" && !FolderCreate(g_baseFolder, g_common))
     {
      Log("", StringFormat("ERROR: cannot create folder %s (error %d)", g_baseFolder, GetLastError()));
      return;
     }
//--- history depth of all symbols
   string status = "finished";
   bool abort = false;
   long first_ticks[];
   datetime bars_starts[];
   ArrayResize(first_ticks, stotal);
   ArrayResize(bars_starts, stotal);
   ArrayInitialize(first_ticks, FIRST_TICK_NOT_SEARCHED);
   ArrayInitialize(bars_starts, 0);
   if(ArraySize(g_tfIdx) > 0 && InpProbeFirstBar)
      Log("", StringFormat("looking for the first M1 bar since %s; the first run for a symbol can take minutes (the terminal downloads its history)",
                           FormatDate(HISTORY_PROBE_FROM)));
   for(int si = 0; si < stotal && !abort; si++)
     {
      int res = LogHistoryInfo(symbols[si], first_ticks[si], bars_starts[si]);
      if(res == RES_STOP)
        {
         status = "stopped by user";
         abort = true;
        }
      else
         if(res == RES_FATAL)
           {
            status = "aborted: connection lost";
            abort = true;
           }
     }
//--- 7. symbol by symbol
   g_lastProgress = GetTickCount64();
   for(int si = 0; si < stotal && !abort; si++)
     {
      string sym = symbols[si];
      if(IsStopped())
        {
         status = "stopped by user";
         break;
        }
      int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      Log(sym, StringFormat("symbol %d/%d, digits=%d", si + 1, stotal, digits));
      if(!FolderCreate(SymbolFolder(sym), g_common))
        {
         Log(sym, StringFormat("ERROR: cannot create folder %s (error %d), symbol skipped", SymbolFolder(sym), GetLastError()));
         int idx = AddStat(sym, "-", false);
         g_stats[idx].errors++;
         continue;
        }
      //--- ticks
      if(InpExportTicks)
        {
         int idx = AddStat(sym, "TICKS", true);
         int res = ExportTicks(si, stotal, sym, digits, first_ticks[si], g_stats[idx]);
         if(res == RES_STOP)
           {
            status = "stopped by user";
            abort = true;
           }
         else
            if(res == RES_FATAL)
              {
               status = "aborted: connection lost";
               abort = true;
              }
        }
      //--- bars
      for(int i = 0; i < ArraySize(g_tfIdx) && !abort; i++)
        {
         string type = g_tfNames[g_tfIdx[i]];
         int idx = AddStat(sym, type, false);
         int res = ExportBars(si, stotal, sym, digits, g_tfValues[g_tfIdx[i]], type, bars_starts[si], g_stats[idx]);
         if(res == RES_STOP)
           {
            status = "stopped by user";
            abort = true;
           }
         else
            if(res == RES_FATAL)
              {
               status = "aborted: connection lost";
               abort = true;
              }
        }
     }
   PrintSummary(status, started);
  }
//+------------------------------------------------------------------+
