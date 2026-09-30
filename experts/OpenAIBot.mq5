//+------------------------------------------------------------------+
//|                                                  experts/OpenAIBot.mq5 |
//|  OpenAI <-> MT5 bridge EA.                                       |
//|                                                                  |
//|  The EA periodically asks the OpenAI chat-completions endpoint    |
//|  to continue the session. The model can request tool calls       |
//|  (trade, market data, account, chart, terminal...). Every tool    |
//|  call is executed locally under risk guardrails, and the result   |
//|  is fed back to the model; the loop repeats until a final text    |
//|  answer arrives.                                                 |
//|                                                                  |
//|  Interaction channels:                                            |
//|    * inbox.txt  (Files\OpenAIBot\\) : lines the EA forwards to    |
//|      the model as new user messages each poll.                    |
//|    * outbox.txt : EA appends assistant answers + tool results.    |
//|    * confirm.txt: when confirmMode=on, trade requests are written |
//|      here and wait for the user to approve/cancel.                |
//|                                                                  |
//|  REQUIREMENTS:                                                    |
//|    * Add https://api.openai.com (or your base URL) to             |
//|      Tools->Options->Expert Advisors->Allow WebRequest...         |
//|    * Set your API key via EA input or config file.                |
//+------------------------------------------------------------------+
#property copyright "MQL5-OpenAI"
#property version   "1.00"
#property strict

#include <OpenAIClient.mqh>
#include <MT5Toolbox.mqh>
#include <Config.mqh>

//--- inputs
input string InpApiKey      = "100216";               // OpenAI API key (local proxy)
input string InpBaseUrl     = "http://host.docker.internal:9936/v1"; // API base URL (local proxy)
input string InpModel       = "DeepSeek-V4-Flash-Official"; // model (local proxy)
input double InpTemperature = 0.2;                    // temperature
input int    InpMaxTokens   = 2000;                   // max tokens per reply
input int    InpMaxToolRounds = 6;                    // max tool-call rounds
input int    InpPollSeconds = 30;                     // poll interval (seconds)
input string InpConfigFile  = "OpenAIBot.ini";        // config file (Files\\)
input string InpSystemPromptFile = "system_prompt.txt"; // prompt file (Files\\)
input int    InpMagic       = 20261030;               // EA magic number

//--- runtime config (populated from inputs, overridable by ini)
string g_apiKey   = "";
string g_baseUrl  = "http://host.docker.internal:9936/v1";
string g_model    = "DeepSeek-V4-Flash-Official";
int    g_maxTokens= 2000;
int    g_pollSeconds = 30;
int    g_magic    = 20261030;
input double InpMaxLot      = 10.0;                   // max lot per order
input int    InpMaxPositions= 5;                      // max open positions
input double InpDailyLoss   = 1000.0;                 // daily loss limit (currency)
input string InpSessions    = "";                     // sessions "HH:MM-HH:MM,..."
input string InpWhitelist   = "*";                    // symbol whitelist
input bool   InpConfirmMode = false;                  // require local confirmation
input bool   InpDryRun      = false;                  // simulate trades only
input bool   InpUseInbox    = true;                   // poll inbox.txt
input string InpSymbol      = "XAUUSD";               // default symbol
input string InpTimeframe   = "H1";                   // default timeframe
input int    InpBarsCount   = 60;                     // bars for context
input int    InpMaxBarText  = 1200;                   // max bar-text length

//--- global objects
COpenAIClient  g_openai;
CMT5Toolbox    g_tb;
SGuardSettings g_guard;
CConfig        g_cfg;

string g_sysPrompt="";
string g_sysPromptFile="";

//--- agent state machine
enum EAgentState
  {
   AG_IDLE=0,        // waiting for next poll
   AG_WORKING,       // a request is in flight (polling)
   AG_ANSWERED,      // final answer received, showing it
   AG_ERROR          // last request failed
  };
EAgentState g_state=AG_IDLE;

string g_lastAnswer="";
string g_lastError="";
datetime g_lastActivity=0;
int g_pollCounter=0;

//--- pending tool calls captured from the assistant
string g_pendingCalls="[]";
string g_pendingIds[];
string g_pendingNames[];
string g_pendingArgs[];
int    g_pendingN=0;

//--- inbox / outbox / confirm file paths
string g_inboxFile="";
string g_outboxFile="";
string g_confirmFile="";
string g_logFile="";
string g_workDir="";

//--- panel
string g_panelName="OpenAIBotPanel";
bool   g_panelCreated=false;

//--- forward declarations
void PanelRefresh(void);
void PanelCreate(void);
string ProcessToolCalls(void);     // returns tool-results JSON array
string DispatchTool(const string name,const string args);
bool   ReadInbox(string &msgs);
void   WriteOutbox(const string text);
bool   LoadConfigAndPrompt(void);
string BuildToolsSchema(void);
string SafePath(const string file);
string TimeStr(const datetime t);

//+------------------------------------------------------------------+
//| expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit(void)
  {
   // ensure Files\OpenAIBot\ exists (MQL5 does not auto-create folders)
   FolderCreate("OpenAIBot");

   g_workDir=TerminalInfoString(TERMINAL_DATA_PATH)+"\\MQL5\\Files\\";
   g_inboxFile=SafePath("OpenAIBot\\inbox.txt");
   g_outboxFile=SafePath("OpenAIBot\\outbox.txt");
   g_confirmFile=SafePath("OpenAIBot\\confirm.txt");
   g_logFile=SafePath("OpenAIBot\\log.txt");

   // default guard
   g_guard.tradingEnabled=true;
   g_guard.maxLot=InpMaxLot;
   g_guard.maxPositions=InpMaxPositions;
   g_guard.dailyLossLimit=InpDailyLoss;
   g_guard.sessions=InpSessions;
   g_guard.symbolsWhitelist=InpWhitelist;
   g_guard.magic=InpMagic;
   g_guard.confirmMode=InpConfirmMode;
   g_guard.dryRun=InpDryRun;
   g_guard.killSwitch=false;
   g_tb.SetGuard(g_guard);
   g_tb.SetLogFile(g_logFile);
   g_tb.SetConfirmFile(g_confirmFile);

   // copy inputs into runtime config
   g_apiKey=InpApiKey;
   g_baseUrl=InpBaseUrl;
   g_model=InpModel;
   g_maxTokens=InpMaxTokens;
   g_pollSeconds=InpPollSeconds;
   g_magic=InpMagic;

   // config file may override
   LoadConfigAndPrompt();

   // tools JSON schema
   string tools=BuildToolsSchema();
   g_openai.Setup(g_apiKey,g_baseUrl,g_model,InpTemperature,g_maxTokens,
                  tools,InpMaxToolRounds);

   // preload symbol data so first poll is fast
   if(SymbolInfoInteger(InpSymbol,SYMBOL_VISIBLE)==0)
      SymbolSelect(InpSymbol,true);

   EventSetTimer(1);
   g_state=AG_IDLE;
   Print("OpenAIBot: initialized. Model=",g_model," base=",g_baseUrl,
         " magic=",g_magic," confirm=",InpConfirmMode," dry=",InpDryRun);
   Print("OpenAIBot: whitelist URL required: ",g_baseUrl);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_panelCreated)
     {
      ObjectDelete(0,g_panelName);
      g_panelCreated=false;
     }
   Print("OpenAIBot: deinitialized (reason=",reason,")");
  }

//+------------------------------------------------------------------+
//| timer: heartbeat                                                 |
//+------------------------------------------------------------------+
void OnTimer(void)
  {
   // 1. refresh panel
   PanelRefresh();

   // 2. countdown until next poll
   g_pollCounter++;
   if(g_pollCounter<g_pollSeconds) return;
   g_pollCounter=0;

   // 3. run one full agent step (blocking HTTP + tool loop)
   StartRequest();
  }

//+------------------------------------------------------------------+
//| run one full agent step (blocking). Drives the tool-calling loop |
//| up to InpMaxToolRounds: send -> execute tools -> feed results -> |
//| send again -> ... until final answer or error.                   |
//+------------------------------------------------------------------+
void StartRequest(void)
  {
   // gather context
   string ctx="";
   ctx+=g_tb.ToolStatus()+"\n";
   ctx+="symbol="+InpSymbol+" timeframe="+InpTimeframe+"\n";
   ctx+="positions:\n"+g_tb.ToolOpenPositions("")+"\n";
   ctx+="today:\n"+g_tb.ToolHistoryToday()+"\n";
   if(InpBarsCount>0)
      ctx+="recent bars "+InpSymbol+" "+InpTimeframe+":\n"+
           g_tb.ToolRates(InpSymbol,InpTimeframe,InpBarsCount)+"\n";

   // limit context size
   if(StringLen(ctx)>InpMaxBarText) ctx=StringSubstr(ctx,0,InpMaxBarText);

   // new user messages from inbox
   string inbox="";
   if(InpUseInbox) ReadInbox(inbox);

   string firstUser="";
   if(inbox!="")
      firstUser=inbox;
   else
      firstUser="(background session; act on current market conditions as appropriate)";

   g_openai.NewConversation(g_sysPrompt,firstUser+"\n\nCONTEXT:\n"+ctx);

   int round=0;
   while(round<InpMaxToolRounds)
     {
      if(!g_openai.SendRequest())
        {
         g_lastError=g_openai.LastError();
         g_state=AG_ERROR;
         Print("OpenAIBot: request failed: ",g_lastError);
         WriteOutbox("ERROR: "+g_lastError);
         return;
        }

      if(g_openai.HasFinalAnswer())
        {
         g_lastAnswer=g_openai.Answer();
         g_state=AG_ANSWERED;
         g_lastActivity=TimeCurrent();
         WriteOutbox("ASSISTANT: "+g_lastAnswer);
         Print("OpenAIBot: answer: ",g_lastAnswer);
         return;
        }

      if(g_openai.PendingCount()>0)
        {
         // model wants tool calls: capture and execute
         g_pendingN=g_openai.PendingCount();
         ArrayResize(g_pendingIds,g_pendingN);
         ArrayResize(g_pendingNames,g_pendingN);
         ArrayResize(g_pendingArgs,g_pendingN);
         for(int i=0;i<g_pendingN;i++)
           {
            g_pendingIds[i]=g_openai.PendingCallId(i);
            g_pendingNames[i]=g_openai.PendingCallName(i);
            g_pendingArgs[i]=g_openai.PendingCallArgs(i);
           }
         g_pendingCalls=g_openai.PendingCallsJson();

         string results=ProcessToolCalls();
         WriteOutbox("TOOLS: "+results);

         // feed results back and continue the loop
         g_openai.FeedToolResults(results);
         round++;
         continue;
        }

      // no answer and no pending calls: unexpected
      g_lastError="assistant returned neither answer nor tool calls";
      g_state=AG_ERROR;
      Print("OpenAIBot: error: ",g_lastError);
      return;
     }

   // round cap reached
   g_lastError="tool-call round limit reached ("+IntegerToString(InpMaxToolRounds)+")";
   g_state=AG_ERROR;
   g_lastActivity=TimeCurrent();
   WriteOutbox("ERROR: "+g_lastError);
   Print("OpenAIBot: ",g_lastError);
  }
//+------------------------------------------------------------------+
//| execute pending tool calls, returns tool-results JSON array      |
//+------------------------------------------------------------------+
string ProcessToolCalls(void)
  {
   string results="[";
   for(int i=0;i<g_pendingN;i++)
     {
      string name=g_pendingNames[i];
      string args=g_pendingArgs[i];
      string out=DispatchTool(name,args);
      string item="{\"role\":\"tool\",\"tool_call_id\":"+CJson::Quote(g_pendingIds[i])+
                  ",\"content\":"+CJson::Quote(out)+"}";
      if(i>0) results+=",";
      results+=item;
     }
   results+="]";
   return results;
  }

//+------------------------------------------------------------------+
//| dispatch one tool call                                            |
//+------------------------------------------------------------------+
string DispatchTool(const string name,const string args)
  {
   CJson j;
   if(!j.Parse(args))
      return "ERROR: cannot parse arguments: "+args;

   if(name=="symbol_info")
      return g_tb.ToolSymbolInfo(j.GetString("symbol",InpSymbol));
   if(name=="rates")
      return g_tb.ToolRates(j.GetString("symbol",InpSymbol),
                            j.GetString("timeframe",InpTimeframe),
                            (int)j.GetInt("count",InpBarsCount));
   if(name=="ticker")
      return g_tb.ToolTicker(j.GetString("symbol",InpSymbol));
   if(name=="indicators")
      return g_tb.ToolIndicators(j.GetString("symbol",InpSymbol),
                                 j.GetString("timeframe",InpTimeframe),
                                 (int)j.GetInt("count",50));
   if(name=="symbols_list")
      return g_tb.ToolSymbolsList();
   if(name=="account_info")
      return g_tb.ToolAccountInfo();
   if(name=="open_positions")
      return g_tb.ToolOpenPositions(j.GetString("symbol",""));
   if(name=="history_today")
      return g_tb.ToolHistoryToday();
   if(name=="open_order")
      return g_tb.ToolOpenOrder(j.GetString("symbol",InpSymbol),
                                (int)j.GetInt("direction",0),
                                j.GetDouble("lot",0.01),
                                j.GetDouble("sl_points",0),
                                j.GetDouble("tp_points",0),
                                j.GetString("comment","OpenAI"));
   if(name=="close_position")
      return g_tb.ToolClosePosition(j.GetString("symbol",""),
                                    (long)j.GetInt("ticket",0),
                                    j.GetDouble("lot",0));
   if(name=="close_all")
      return g_tb.ToolCloseAll(j.GetString("symbol",""));
   if(name=="modify_position")
      return g_tb.ToolModifyPosition((long)j.GetInt("ticket",0),
                                     j.GetDouble("sl_points",-1),
                                     j.GetDouble("tp_points",-1));
   if(name=="trailing_stop")
      return g_tb.ToolTrailingStop((long)j.GetInt("ticket",0),
                                   j.GetDouble("trail_points",0));
   if(name=="delete_pending")
      return g_tb.ToolDeletePending(j.GetString("symbol",""),
                                    (long)j.GetInt("ticket",0));
   if(name=="open_chart")
      return g_tb.ToolOpenChart(j.GetString("symbol",InpSymbol),
                                j.GetString("timeframe",InpTimeframe));
   if(name=="chart_object")
      return g_tb.ToolChartObject(j.GetString("symbol",InpSymbol),
                                  j.GetString("timeframe",InpTimeframe),
                                  j.GetString("kind","hline"),
                                  j.GetDouble("price",0),
                                  j.GetString("text",""));
   if(name=="popup")
      return g_tb.ToolPopup(j.GetString("title","OpenAI"),
                            j.GetString("message",""));
   if(name=="log")
      return g_tb.ToolLog(j.GetString("message",""));
   if(name=="status")
      return g_tb.ToolStatus();
   if(name=="set_guard")
      return g_tb.ToolSetGuard(j.GetString("key",""),
                               j.GetString("value",""));

   return "ERROR: unknown tool: "+name;
  }

//+------------------------------------------------------------------+
//| inbox: read queued user messages                                  |
//+------------------------------------------------------------------+
bool ReadInbox(string &msgs)
  {
   msgs="";
   int h=FileOpen(g_inboxFile,FILE_READ|FILE_TXT|FILE_ANSI);
   if(h==INVALID_HANDLE) return false;
   while(!FileIsEnding(h))
     {
      string line=FileReadString(h);
      StringTrimRight(line);
      if(line=="") continue;
      msgs+=line+"\n";
     }
   FileClose(h);
   // clear the inbox after reading
   int w=FileOpen(g_inboxFile,FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(w!=INVALID_HANDLE) FileClose(w);
   return (msgs!="");
  }

//+------------------------------------------------------------------+
//| outbox: append assistant text                                     |
//+------------------------------------------------------------------+
void WriteOutbox(const string text)
  {
   CFileLog::Write(g_outboxFile,TimeStr(TimeCurrent())+" "+text);
  }

//+------------------------------------------------------------------+
//| safe path helper                                                  |
//+------------------------------------------------------------------+
string SafePath(const string file)
  {
   // files are stored under MQL5\Files\OpenAIBot\
   return "OpenAIBot\\"+file;
  }

string TimeStr(const datetime t)
  {
   return TimeToString(t,TIME_DATE|TIME_SECONDS);
  }

//+------------------------------------------------------------------+
//| load config + system prompt                                       |
//+------------------------------------------------------------------+
bool LoadConfigAndPrompt(void)
  {
   bool ok=false;
   string cfgPath=SafePath(InpConfigFile);
   if(g_cfg.Load(cfgPath))
     {
      if(g_cfg.Has("api_key") && g_cfg.GetString("api_key")!="")
         g_apiKey=g_cfg.GetString("api_key");
      if(g_cfg.Has("base_url"))    g_baseUrl=g_cfg.GetString("base_url");
      if(g_cfg.Has("model"))       g_model=g_cfg.GetString("model");
      if(g_cfg.Has("max_tokens"))  g_maxTokens=g_cfg.GetInt("max_tokens");
      if(g_cfg.Has("poll_seconds"))g_pollSeconds=g_cfg.GetInt("poll_seconds");
      if(g_cfg.Has("magic"))       g_magic=g_cfg.GetInt("magic");
      if(g_cfg.Has("max_lot"))     g_guard.maxLot=g_cfg.GetDouble("max_lot");
      if(g_cfg.Has("max_positions"))g_guard.maxPositions=g_cfg.GetInt("max_positions");
      if(g_cfg.Has("daily_loss"))  g_guard.dailyLossLimit=g_cfg.GetDouble("daily_loss");
      if(g_cfg.Has("sessions"))    g_guard.sessions=g_cfg.GetString("sessions");
      if(g_cfg.Has("whitelist"))   g_guard.symbolsWhitelist=g_cfg.GetString("whitelist");
      if(g_cfg.Has("confirm_mode"))g_guard.confirmMode=g_cfg.GetBool("confirm_mode");
      if(g_cfg.Has("dry_run"))     g_guard.dryRun=g_cfg.GetBool("dry_run");
      ok=true;
     }
   // system prompt
   g_sysPromptFile=SafePath(InpSystemPromptFile);
   int h=FileOpen(g_sysPromptFile,FILE_READ|FILE_TXT|FILE_ANSI);
   if(h!=INVALID_HANDLE)
     {
      g_sysPrompt="";
      while(!FileIsEnding(h))
         g_sysPrompt+=FileReadString(h)+"\n";
      FileClose(h);
     }
   else
     {
      g_sysPrompt="You are a trading assistant connected to a MetaTrader 5 terminal. "+
                  "You can read market data, account info and positions, and place/manage "+
                  "trades via tool calls. Always respect guardrail replies: if a tool "+
                  "returns DENIED, explain why and suggest the user adjust settings. "+
                  "Use precise numbers and never invent prices.";
     }
   g_tb.SetGuard(g_guard);
   return ok;
  }

//+------------------------------------------------------------------+
//| tool schema JSON (OpenAI function definitions)                   |
//+------------------------------------------------------------------+
string BuildToolsSchema(void)
  {
   string tools="[";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"symbol_info\",\"description\":\"Get symbol specification: digits, point, tick size/value, spread, volume limits, stops level, swap, margin, filling mode\",\"parameters\":{\"type\":\"object\",\"properties\":{\"symbol\":{\"type\":\"string\",\"description\":\"e.g. EURUSD\"}},\"required\":[\"symbol\"]}}},";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"rates\",\"description\":\"Get recent OHLC bars for a symbol and timeframe\",\"parameters\":{\"type\":\"object\",\"properties\":{\"symbol\":{\"type\":\"string\"},\"timeframe\":{\"type\":\"string\",\"enum\":[\"m1\",\"m5\",\"m15\",\"m30\",\"h1\",\"h4\",\"d1\",\"w1\"],\"description\":\"default H1\"},\"count\":{\"type\":\"integer\",\"description\":\"number of bars, default 60, max 1000\"}},\"required\":[\"symbol\"]}}},";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"ticker\",\"description\":\"Latest bid/ask for a symbol\",\"parameters\":{\"type\":\"object\",\"properties\":{\"symbol\":{\"type\":\"string\"}},\"required\":[\"symbol\"]}}},";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"indicators\",\"description\":\"Technical indicators: MA14, RSI14, ATR14, MACD, Bollinger, Stochastic + recent closes\",\"parameters\":{\"type\":\"object\",\"properties\":{\"symbol\":{\"type\":\"string\"},\"timeframe\":{\"type\":\"string\",\"enum\":[\"m1\",\"m5\",\"m15\",\"m30\",\"h1\",\"h4\",\"d1\",\"w1\"]},\"count\":{\"type\":\"integer\",\"default\":50}},\"required\":[\"symbol\"]}}},";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"symbols_list\",\"description\":\"List all visible symbols\",\"parameters\":{\"type\":\"object\",\"properties\":{}}}},";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"account_info\",\"description\":\"Account balance, equity, margin, free margin, leverage, currency\",\"parameters\":{\"type\":\"object\",\"properties\":{}}}},";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"open_positions\",\"description\":\"List open positions with this EA magic\",\"parameters\":{\"type\":\"object\",\"properties\":{\"symbol\":{\"type\":\"string\",\"description\":\"filter, empty=all\"}}}},";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"history_today\",\"description\":\"Today's closed deals + total P/L\",\"parameters\":{\"type\":\"object\",\"properties\":{}}}},";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"open_order\",\"description\":\"Open a market BUY/SELL position with optional SL/TP in points. Guardrails enforced.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"symbol\":{\"type\":\"string\"},\"direction\":{\"type\":\"integer\",\"enum\":[0,1],\"description\":\"0=BUY 1=SELL\"},\"lot\":{\"type\":\"number\",\"description\":\"volume\"},\"sl_points\":{\"type\":\"number\",\"description\":\"stop loss distance in points from entry, 0=none\"},\"tp_points\":{\"type\":\"number\",\"description\":\"take profit distance in points from entry, 0=none\"},\"comment\":{\"type\":\"string\"}},\"required\":[\"symbol\",\"direction\",\"lot\"]}}},";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"close_position\",\"description\":\"Close an open position by ticket (or by symbol if ticket=0)\",\"parameters\":{\"type\":\"object\",\"properties\":{\"ticket\":{\"type\":\"integer\",\"description\":\"position ticket, 0=by symbol\"},\"symbol\":{\"type\":\"string\"},\"lot\":{\"type\":\"number\",\"description\":\"partial volume, 0=all\"}}}},";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"close_all\",\"description\":\"Close all positions of this EA (optionally by symbol)\",\"parameters\":{\"type\":\"object\",\"properties\":{\"symbol\":{\"type\":\"string\"}}}}},";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"modify_position\",\"description\":\"Modify SL/TP of a position by points from open price (>=0 set, <0 keep)\",\"parameters\":{\"type\":\"object\",\"properties\":{\"ticket\":{\"type\":\"integer\"},\"sl_points\":{\"type\":\"number\"},\"tp_points\":{\"type\":\"number\"}},\"required\":[\"ticket\"]}}},";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"trailing_stop\",\"description\":\"Move SL to trail distance behind current price (never backwards)\",\"parameters\":{\"type\":\"object\",\"properties\":{\"ticket\":{\"type\":\"integer\"},\"trail_points\":{\"type\":\"number\"}},\"required\":[\"ticket\",\"trail_points\"]}}},";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"delete_pending\",\"description\":\"Delete a pending order by ticket\",\"parameters\":{\"type\":\"object\",\"properties\":{\"ticket\":{\"type\":\"integer\"},\"symbol\":{\"type\":\"string\"}},\"required\":[\"ticket\"]}}},";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"open_chart\",\"description\":\"Open a chart window for a symbol/timeframe\",\"parameters\":{\"type\":\"object\",\"properties\":{\"symbol\":{\"type\":\"string\"},\"timeframe\":{\"type\":\"string\",\"enum\":[\"m1\",\"m5\",\"m15\",\"m30\",\"h1\",\"h4\",\"d1\",\"w1\"]}},\"required\":[\"symbol\"]}}},";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"chart_object\",\"description\":\"Add a chart object: hline, vline, text, label, arrow\",\"parameters\":{\"type\":\"object\",\"properties\":{\"symbol\":{\"type\":\"string\"},\"timeframe\":{\"type\":\"string\"},\"kind\":{\"type\":\"string\",\"enum\":[\"hline\",\"vline\",\"text\",\"label\",\"arrow\"]},\"price\":{\"type\":\"number\"},\"text\":{\"type\":\"string\"}},\"required\":[\"kind\"]}}},";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"popup\",\"description\":\"Show an alert popup in the terminal\",\"parameters\":{\"type\":\"object\",\"properties\":{\"title\":{\"type\":\"string\"},\"message\":{\"type\":\"string\"}},\"required\":[\"title\",\"message\"]}}},";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"log\",\"description\":\"Write a message to the EA log\",\"parameters\":{\"type\":\"object\",\"properties\":{\"message\":{\"type\":\"string\"}},\"required\":[\"message\"]}}},";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"status\",\"description\":\"Show current guardrail status and account snapshot\",\"parameters\":{\"type\":\"object\",\"properties\":{}}}},";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"set_guard\",\"description\":\"Change a guardrail setting: trading, kill, max_lot, max_positions, daily_loss_limit, sessions, whitelist, confirm_mode, dry_run\",\"parameters\":{\"type\":\"object\",\"properties\":{\"key\":{\"type\":\"string\"},\"value\":{\"type\":\"string\"}},\"required\":[\"key\",\"value\"]}}}";
   tools+="]";
   return tools;
  }

//+------------------------------------------------------------------+
//| panel                                                            |
//+------------------------------------------------------------------+
void PanelCreate(void)
  {
   if(g_panelCreated) return;
   if(!ObjectCreate(0,g_panelName,OBJ_LABEL,0,0,0)) return;
   ObjectSetInteger(0,g_panelName,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,g_panelName,OBJPROP_XDISTANCE,10);
   ObjectSetInteger(0,g_panelName,OBJPROP_YDISTANCE,20);
   ObjectSetInteger(0,g_panelName,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,g_panelName,OBJPROP_HIDDEN,true);
   g_panelCreated=true;
  }

void PanelRefresh(void)
  {
   PanelCreate();
   if(!g_panelCreated) return;
   string s="OpenAIBot v1.00\n";
   s+="state: ";
   switch(g_state)
     {
      case AG_IDLE:    s+="IDLE"; break;
      case AG_WORKING: s+="WORKING"; break;
      case AG_ANSWERED:s+="ANSWERED"; break;
      case AG_ERROR:   s+="ERROR"; break;
     }
   s+="\nmodel: "+g_model;
   s+="\nlast activity: "+(g_lastActivity>0?TimeStr(g_lastActivity):"-");
   s+="\npositions: "+IntegerToString(PositionsTotal());
   s+="\nequity: "+DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY),2);
   s+="\nmargin free: "+DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE),2);
   if(g_state==AG_ANSWERED && g_lastAnswer!="")
      s+="\nlast answer:\n"+StringSubstr(g_lastAnswer,0,200);
   if(g_state==AG_ERROR && g_lastError!="")
      s+="\nlast error:\n"+StringSubstr(g_lastError,0,200);
   ObjectSetString(0,g_panelName,OBJPROP_TEXT,s);
  }

//+------------------------------------------------------------------+
//| ticks: keep the panel responsive (also used as heartbeat)        |
//+------------------------------------------------------------------+
void OnTick(void)
  {
   PanelRefresh();
  }
//+------------------------------------------------------------------+
