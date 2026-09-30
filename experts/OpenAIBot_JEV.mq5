//+------------------------------------------------------------------+
//|                                           experts/OpenAIBot_JEV.mq5 |
//|  JEV edition: same architecture as OpenAIBot.mq5 but tuned for   |
//|  the TypeSafe JEV model served via OpenRouter.                   |
//|                                                                  |
//|  Differences vs OpenAIBot.mq5:                                   |
//|    * model   = typesafe/jev-1.13  (OpenRouter slug)              |
//|    * base    = https://openrouter.ai/api/v1                      |
//|    * auth    = Bearer <OpenRouter API key> (sk-or-...)           |
//|    * context = 32K tokens -> trimmed tool schema (15 functions), |
//|      trimmed context (fewer bars, tighter fields), lower         |
//|      max_tokens and poll interval.                               |
//|                                                                  |
//|  URL whitelist: add https://openrouter.ai in MT5 WebRequest      |
//|  settings (Tools->Options->Expert Advisors).                     |
//+------------------------------------------------------------------+
#property copyright "MQL5-OpenAI"
#property version   "1.10"

#include "..\include\OpenAIClient.mqh"
#include "..\include\MT5Toolbox.mqh"
#include "..\include\Config.mqh"

//--- inputs
input string InpApiKey      = "";                        // OpenRouter API key (sk-or-...)
input string InpBaseUrl     = "https://openrouter.ai/api/v1"; // API base URL
input string InpModel       = "typesafe/jev-1.13";       // model
input double InpTemperature = 0.2;                       // temperature
input int    InpMaxTokens   = 1000;                      // max tokens per reply (32K ctx)
input int    InpMaxToolRounds = 4;                       // max tool-call rounds
input int    InpPollSeconds = 45;                        // poll interval (seconds)
input string InpConfigFile  = "OpenAIBot_JEV.ini";       // config file (Files\\)
input string InpSystemPromptFile = "system_prompt.txt";  // prompt file (Files\\)
input int    InpMagic       = 20261030;                  // EA magic number
input double InpMaxLot      = 10.0;                      // max lot per order
input int    InpMaxPositions= 5;                         // max open positions
input double InpDailyLoss   = 1000.0;                    // daily loss limit (currency)
input string InpSessions    = "";                        // sessions "HH:MM-HH:MM,..."
input string InpWhitelist   = "*";                       // symbol whitelist
input bool   InpConfirmMode = false;                     // require local confirmation
input bool   InpDryRun      = true;                      // simulate trades only (JEV default ON)
input bool   InpUseInbox    = true;                      // poll inbox.txt
input string InpSymbol      = "EURUSD";                  // default symbol
input string InpTimeframe   = "H1";                      // default timeframe
input int    InpBarsCount   = 30;                        // bars for context (JEV: keep small)
input int    InpMaxBarText  = 600;                       // max bar-text length (JEV: tighter)

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
   AG_IDLE=0,
   AG_WORKING,
   AG_ANSWERED,
   AG_ERROR
  };
EAgentState g_state=AG_IDLE;

string g_lastAnswer="";
string g_lastError="";
datetime g_lastActivity=0;
int g_pollCounter=0;

//--- pending tool calls captured from the assistant
string g_pendingIds[];
string g_pendingNames[];
string g_pendingArgs[];
int    g_pendingN=0;

//--- inbox / outbox / confirm file paths
string g_inboxFile="";
string g_outboxFile="";
string g_confirmFile="";
string g_logFile="";

//--- panel
string g_panelName="OpenAIBotJevPanel";
bool   g_panelCreated=false;

//--- forward declarations
void PanelRefresh(void);
void PanelCreate(void);
string ProcessToolCalls(void);
string DispatchTool(const string name,const string args);
bool   ReadInbox(string &msgs);
void   WriteOutbox(const string text);
bool   LoadConfigAndPrompt(void);
string BuildToolsSchema(void);
string TimeStr(const datetime t);

//+------------------------------------------------------------------+
//| expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit(void)
  {
   // ensure Files\OpenAIBot\ exists
   FolderCreate("OpenAIBot");

   g_inboxFile="OpenAIBot\\inbox.txt";
   g_outboxFile="OpenAIBot\\outbox.txt";
   g_confirmFile="OpenAIBot\\confirm.txt";
   g_logFile="OpenAIBot\\log.txt";

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

   // config file may override
   LoadConfigAndPrompt();

   // tools JSON schema (JEV-trimmed) + history trim for 32K context
   string tools=BuildToolsSchema();
   g_openai.Setup(InpApiKey,InpBaseUrl,InpModel,InpTemperature,InpMaxTokens,
                  tools,InpMaxToolRounds,12000);

   // preload symbol data
   if(SymbolInfoInteger(InpSymbol,SYMBOL_VISIBLE)==0)
      SymbolSelect(InpSymbol,true);

   EventSetTimer(1);
   g_state=AG_IDLE;
   Print("OpenAIBot_JEV: initialized. model=",InpModel," base=",InpBaseUrl,
         " magic=",InpMagic," confirm=",InpConfirmMode," dry=",InpDryRun);
   Print("OpenAIBot_JEV: whitelist URL required: https://openrouter.ai");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_panelCreated)
     {
      ObjectDelete(0,g_panelName);
      g_panelCreated=false;
     }
   Print("OpenAIBot_JEV: deinitialized (reason=",reason,")");
  }

//+------------------------------------------------------------------+
void OnTimer(void)
  {
   PanelRefresh();

   g_pollCounter++;
   if(g_pollCounter<InpPollSeconds) return;
   g_pollCounter=0;

   StartRequest();
  }

//+------------------------------------------------------------------+
//| run one full agent step (blocking HTTP + tool loop)              |
//+------------------------------------------------------------------+
void StartRequest(void)
  {
   // gather context (JEV-trimmed: fewer bars, no history dump)
   string ctx="";
   ctx+=g_tb.ToolStatus()+"\n";
   ctx+="symbol="+InpSymbol+" timeframe="+InpTimeframe+"\n";
   ctx+="positions:\n"+g_tb.ToolOpenPositions("")+"\n";
   if(InpBarsCount>0)
      ctx+="recent bars "+InpSymbol+" "+InpTimeframe+":\n"+
           g_tb.ToolRates(InpSymbol,InpTimeframe,InpBarsCount)+"\n";

   if(StringLen(ctx)>InpMaxBarText) ctx=StringSubstr(ctx,0,InpMaxBarText);

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
         Print("OpenAIBot_JEV: request failed: ",g_lastError);
         WriteOutbox("ERROR: "+g_lastError);
         return;
        }

      if(g_openai.HasFinalAnswer())
        {
         g_lastAnswer=g_openai.Answer();
         g_state=AG_ANSWERED;
         g_lastActivity=TimeCurrent();
         WriteOutbox("ASSISTANT: "+g_lastAnswer);
         Print("OpenAIBot_JEV: answer: ",g_lastAnswer);
         return;
        }

      if(g_openai.PendingCount()>0)
        {
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

         string results=ProcessToolCalls();
         WriteOutbox("TOOLS: "+results);

         g_openai.FeedToolResults(results);
         round++;
         continue;
        }

      g_lastError="assistant returned neither answer nor tool calls";
      g_state=AG_ERROR;
      Print("OpenAIBot_JEV: error: ",g_lastError);
      return;
     }

   g_lastError="tool-call round limit reached ("+IntegerToString(InpMaxToolRounds)+")";
   g_state=AG_ERROR;
   g_lastActivity=TimeCurrent();
   WriteOutbox("ERROR: "+g_lastError);
   Print("OpenAIBot_JEV: ",g_lastError);
  }

//+------------------------------------------------------------------+
string ProcessToolCalls(void)
  {
   string results="[";
   for(int i=0;i<g_pendingN;i++)
     {
      string out=DispatchTool(g_pendingNames[i],g_pendingArgs[i]);
      string item="{\"role\":\"tool\",\"tool_call_id\":"+CJson::Quote(g_pendingIds[i])+
                  ",\"content\":"+CJson::Quote(out)+"}";
      if(i>0) results+=",";
      results+=item;
     }
   results+="]";
   return results;
  }

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
                                 (int)j.GetInt("count",30));
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
                                j.GetString("comment","JEV"));
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
      return g_tb.ToolPopup(j.GetString("title","JEV"),
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
   int w=FileOpen(g_inboxFile,FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(w!=INVALID_HANDLE) FileClose(w);
   return (msgs!="");
  }

//+------------------------------------------------------------------+
void WriteOutbox(const string text)
  {
   CFileLog::Write(g_outboxFile,TimeStr(TimeCurrent())+" "+text);
  }

//+------------------------------------------------------------------+
string TimeStr(const datetime t)
  {
   return TimeToString(t,TIME_DATE|TIME_SECONDS);
  }

//+------------------------------------------------------------------+
bool LoadConfigAndPrompt(void)
  {
   bool ok=false;
   string cfgPath="OpenAIBot\\"+InpConfigFile;
   if(g_cfg.Load(cfgPath))
     {
      if(g_cfg.Has("api_key") && g_cfg.GetString("api_key")!="")
         InpApiKey=g_cfg.GetString("api_key");
      if(g_cfg.Has("base_url"))    InpBaseUrl=g_cfg.GetString("base_url");
      if(g_cfg.Has("model"))       InpModel=g_cfg.GetString("model");
      if(g_cfg.Has("max_tokens"))  InpMaxTokens=g_cfg.GetInt("max_tokens");
      if(g_cfg.Has("poll_seconds"))InpPollSeconds=g_cfg.GetInt("poll_seconds");
      if(g_cfg.Has("magic"))       InpMagic=g_cfg.GetInt("magic");
      if(g_cfg.Has("max_lot"))     g_guard.maxLot=g_cfg.GetDouble("max_lot");
      if(g_cfg.Has("max_positions"))g_guard.maxPositions=g_cfg.GetInt("max_positions");
      if(g_cfg.Has("daily_loss"))  g_guard.dailyLossLimit=g_cfg.GetDouble("daily_loss");
      if(g_cfg.Has("sessions"))    g_guard.sessions=g_cfg.GetString("sessions");
      if(g_cfg.Has("whitelist"))   g_guard.symbolsWhitelist=g_cfg.GetString("whitelist");
      if(g_cfg.Has("confirm_mode"))g_guard.confirmMode=g_cfg.GetBool("confirm_mode");
      if(g_cfg.Has("dry_run"))     g_guard.dryRun=g_cfg.GetBool("dry_run");
      ok=true;
     }
   // system prompt (shared with main EA)
   int h=FileOpen("OpenAIBot\\system_prompt.txt",FILE_READ|FILE_TXT|FILE_ANSI);
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
//| JEV-trimmed tool schema (15 functions, 32K context budget)       |
//+------------------------------------------------------------------+
string BuildToolsSchema(void)
  {
   string tools="[";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"symbol_info\",\"description\":\"Symbol spec: digits, point, spread, volume limits, stops level\",\"parameters\":{\"type\":\"object\",\"properties\":{\"symbol\":{\"type\":\"string\"}},\"required\":[\"symbol\"]}}},";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"ticker\",\"description\":\"Latest bid/ask\",\"parameters\":{\"type\":\"object\",\"properties\":{\"symbol\":{\"type\":\"string\"}},\"required\":[\"symbol\"]}}},";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"rates\",\"description\":\"Recent OHLC bars\",\"parameters\":{\"type\":\"object\",\"properties\":{\"symbol\":{\"type\":\"string\"},\"timeframe\":{\"type\":\"string\",\"enum\":[\"m1\",\"m5\",\"m15\",\"m30\",\"h1\",\"h4\",\"d1\",\"w1\"]},\"count\":{\"type\":\"integer\",\"default\":30,\"maximum\":200}},\"required\":[\"symbol\"]}}},";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"indicators\",\"description\":\"MA, RSI, ATR, MACD, Bollinger, Stoch\",\"parameters\":{\"type\":\"object\",\"properties\":{\"symbol\":{\"type\":\"string\"},\"timeframe\":{\"type\":\"string\",\"enum\":[\"m1\",\"m5\",\"m15\",\"m30\",\"h1\",\"h4\",\"d1\",\"w1\"]}},\"required\":[\"symbol\"]}}},";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"account_info\",\"description\":\"Balance, equity, margin, leverage\",\"parameters\":{\"type\":\"object\",\"properties\":{}}}},";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"open_positions\",\"description\":\"Open positions of this EA\",\"parameters\":{\"type\":\"object\",\"properties\":{\"symbol\":{\"type\":\"string\"}}}}},";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"history_today\",\"description\":\"Today closed deals + P/L\",\"parameters\":{\"type\":\"object\",\"properties\":{}}}},";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"open_order\",\"description\":\"Open market BUY/SELL with SL/TP points. Guardrails enforced.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"symbol\":{\"type\":\"string\"},\"direction\":{\"type\":\"integer\",\"enum\":[0,1]},\"lot\":{\"type\":\"number\"},\"sl_points\":{\"type\":\"number\"},\"tp_points\":{\"type\":\"number\"},\"comment\":{\"type\":\"string\"}},\"required\":[\"symbol\",\"direction\",\"lot\"]}}},";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"close_position\",\"description\":\"Close by ticket (0=symbol)\",\"parameters\":{\"type\":\"object\",\"properties\":{\"ticket\":{\"type\":\"integer\"},\"symbol\":{\"type\":\"string\"},\"lot\":{\"type\":\"number\"}}}}},";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"close_all\",\"description\":\"Close all EA positions\",\"parameters\":{\"type\":\"object\",\"properties\":{\"symbol\":{\"type\":\"string\"}}}}},";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"modify_position\",\"description\":\"Modify SL/TP by points from open (>=0 set, <0 keep)\",\"parameters\":{\"type\":\"object\",\"properties\":{\"ticket\":{\"type\":\"integer\"},\"sl_points\":{\"type\":\"number\"},\"tp_points\":{\"type\":\"number\"}},\"required\":[\"ticket\"]}}},";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"trailing_stop\",\"description\":\"Trail SL behind price (never backwards)\",\"parameters\":{\"type\":\"object\",\"properties\":{\"ticket\":{\"type\":\"integer\"},\"trail_points\":{\"type\":\"number\"}},\"required\":[\"ticket\",\"trail_points\"]}}},";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"delete_pending\",\"description\":\"Delete pending order\",\"parameters\":{\"type\":\"object\",\"properties\":{\"ticket\":{\"type\":\"integer\"}},\"required\":[\"ticket\"]}}},";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"open_chart\",\"description\":\"Open chart\",\"parameters\":{\"type\":\"object\",\"properties\":{\"symbol\":{\"type\":\"string\"},\"timeframe\":{\"type\":\"string\"}},\"required\":[\"symbol\"]}}},";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"popup\",\"description\":\"Show alert popup\",\"parameters\":{\"type\":\"object\",\"properties\":{\"title\":{\"type\":\"string\"},\"message\":{\"type\":\"string\"}},\"required\":[\"title\",\"message\"]}}},";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"log\",\"description\":\"Write EA log\",\"parameters\":{\"type\":\"object\",\"properties\":{\"message\":{\"type\":\"string\"}},\"required\":[\"message\"]}}},";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"status\",\"description\":\"Guardrail + account snapshot\",\"parameters\":{\"type\":\"object\",\"properties\":{}}}},";
   tools+="{\"type\":\"function\",\"function\":{\"name\":\"set_guard\",\"description\":\"Change guardrail: trading, kill, max_lot, max_positions, daily_loss_limit, sessions, whitelist, confirm_mode, dry_run\",\"parameters\":{\"type\":\"object\",\"properties\":{\"key\":{\"type\":\"string\"},\"value\":{\"type\":\"string\"}},\"required\":[\"key\",\"value\"]}}}";
   tools+="]";
   return tools;
  }

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
   string s="OpenAIBot JEV v1.10\n";
   s+="state: ";
   switch(g_state)
     {
      case AG_IDLE:    s+="IDLE"; break;
      case AG_WORKING: s+="WORKING"; break;
      case AG_ANSWERED:s+="ANSWERED"; break;
      case AG_ERROR:   s+="ERROR"; break;
     }
   s+="\nmodel: "+InpModel;
   s+="\nlast activity: "+(g_lastActivity>0?TimeStr(g_lastActivity):"-");
   s+="\npositions: "+IntegerToString(PositionsTotal());
   s+="\nequity: "+DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY),2);
   s+="\nmargin free: "+DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE),2);
   if(g_state==AG_ANSWERED && g_lastAnswer!="")
      s+="\nlast answer:\n"+StringSubstr(g_lastAnswer,0,150);
   if(g_state==AG_ERROR && g_lastError!="")
      s+="\nlast error:\n"+StringSubstr(g_lastError,0,150);
   ObjectSetString(0,g_panelName,OBJPROP_TEXT,s);
  }

//+------------------------------------------------------------------+
void OnTick(void)
  {
   PanelRefresh();
  }
//+------------------------------------------------------------------+
