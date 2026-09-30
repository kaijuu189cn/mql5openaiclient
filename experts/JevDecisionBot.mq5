//+------------------------------------------------------------------+
//|                                          experts/JevDecisionBot.mq5 |
//|  JEV decision-gate EA.                                           |
//|                                                                  |
//|  Jev (typesafe/jev-1.13 on OpenRouter) is a System One DECISION  |
//|  model, not a chat model. It returns typed answers with          |
//|  probabilities. This EA uses it as a decision gate for trading:  |
//|                                                                  |
//|    1. On each poll, build a market snapshot (state).             |
//|    2. Ask Jev a Choice question: trade / hold / close.            |
//|    3. If confidence >= threshold and the chosen action is         |
//|       profitable-per-guardrails, execute via CMT5Toolbox.         |
//|                                                                  |
//|  Signal sources (choose via input):                              |
//|    * inbox.txt : a line "open EURUSD BUY 0.1" etc. written by     |
//|      another EA / script; Jev approves or blocks it.              |
//|    * local    : built-in simple momentum rule generates the       |
//|      candidate, Jev decides whether to act.                       |
//|                                                                  |
//|  All trading still passes the R1-R8 guardrails in MT5Toolbox.    |
//|                                                                  |
//|  URL whitelist: add https://openrouter.ai in MT5 WebRequest.     |
//+------------------------------------------------------------------+
#property copyright "MQL5-OpenAI"
#property version   "1.20"

#include <JevClient.mqh>
#include <MT5Toolbox.mqh>
#include <Config.mqh>

//--- inputs
input string InpApiKey      = "";                          // OpenRouter API key (sk-or-...)
input string InpBaseUrl     = "https://openrouter.ai";      // OpenRouter base
input string InpModel       = "typesafe/jev-1.13";          // JEV model
input int    InpPollSeconds = 60;                           // decision interval
input double InpMinConf     = 0.60;                         // min confidence to act
input double InpMinProb     = 0.55;                         // min option probability to act
input int    InpSignalMode  = 1;                            // 1=inbox signal 2=local momentum
input int    InpMagic       = 20261031;                     // JEV EA magic
input double InpMaxLot      = 10.0;                         // guard: max lot
input int    InpMaxPositions= 5;                            // guard: max positions
input double InpDailyLoss   = 1000.0;                       // guard: daily loss limit
input string InpSessions    = "";                           // guard: sessions
input string InpWhitelist   = "*";                          // guard: symbol whitelist
input bool   InpConfirmMode = false;                        // guard: confirm mode
input bool   InpDryRun      = true;                         // guard: dry run (default ON)
input string InpSymbol      = "XAUUSD";                     // default symbol
input string InpTimeframe   = "H1";                         // default timeframe
input int    InpBarsCount   = 30;                           // bars for state

//--- globals
CJevClient     g_jev;
CMT5Toolbox    g_tb;
SGuardSettings g_guard;
CConfig        g_cfg;

string g_inboxFile="OpenAIBot\\inbox.txt";
string g_outboxFile="OpenAIBot\\outbox.txt";
string g_logFile="OpenAIBot\\log.txt";
int    g_pollCounter=0;

//--- panel
string g_panelName="JevDecisionPanel";
bool   g_panelCreated=false;

//--- forward
void PanelRefresh(void);
void PanelCreate(void);
bool ReadInboxSignal(string &sym,int &dir,double &lot);
string BuildState(void);
string BuildQuestions(void);
string DoLocalSignal(string &sym,int &dir,double &lot);
string ExecuteCandidate(const string sym,const int dir,const double lot);

//+------------------------------------------------------------------+
int OnInit(void)
  {
   FolderCreate("OpenAIBot");

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

   g_jev.Setup(InpApiKey,InpBaseUrl,InpModel);

   if(SymbolInfoInteger(InpSymbol,SYMBOL_VISIBLE)==0)
      SymbolSelect(InpSymbol,true);

   EventSetTimer(1);
   Print("JevDecisionBot: init model=",InpModel," conf>=",InpMinConf,
         " prob>=",InpMinProb," mode=",InpSignalMode,
         " dry=",InpDryRun," magic=",InpMagic);
   Print("JevDecisionBot: whitelist https://openrouter.ai in WebRequest");
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_panelCreated)
     {
      ObjectDelete(0,g_panelName);
      g_panelCreated=false;
     }
   Print("JevDecisionBot: deinit (reason=",reason,")");
  }

//+------------------------------------------------------------------+
void OnTimer(void)
  {
   PanelRefresh();
   g_pollCounter++;
   if(g_pollCounter<InpPollSeconds) return;
   g_pollCounter=0;

   // 1. candidate signal
   string sym=InpSymbol; int dir=0; double lot=0.1;
   string src="";
   if(InpSignalMode==1)
     {
      if(!ReadInboxSignal(sym,dir,lot))
        {
         Print("JevDecisionBot: no inbox signal, skip");
         return;
        }
      src="inbox";
     }
   else
     {
      string err=DoLocalSignal(sym,dir,lot);
      if(err!="")
        {
         Print("JevDecisionBot: local signal: ",err);
         return;
        }
      src="local";
     }

   // 2. ask Jev
   string state=BuildState();
   string questions=BuildQuestions();
   if(!g_jev.Decide(state,questions))
     {
      Print("JevDecisionBot: decide failed: ",g_jev.LastError());
      return;
     }

   // 3. read answers
   string action=g_jev.ChoiceValue("action");
   double prob=g_jev.ChoiceProbability("action",action);
   double conf=g_jev.ChoiceConfidence("action");
   double noul=g_jev.NoulValue("proceed");

   Print("JevDecisionBot: action=",action," prob=",DoubleToString(prob,2),
         " conf=",DoubleToString(conf,2)," noul=",DoubleToString(noul,2));

   // 4. gate
   if(action=="hold")
     {
      Print("JevDecisionBot: HOLD (no trade)");
      CFileLog::Write(g_outboxFile,TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS)+
                      " JEV:"+action+" prob="+DoubleToString(prob,2)+" conf="+DoubleToString(conf,2));
      return;
     }
   if(action=="close")
     {
      string r=g_tb.ToolCloseAll(sym);
      Print("JevDecisionBot: CLOSE -> ",r);
      CFileLog::Write(g_outboxFile,TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS)+" "+r);
      return;
     }
   if(action!="open")
     {
      Print("JevDecisionBot: unknown action ",action);
      return;
     }
   if(conf<InpMinConf || prob<InpMinProb)
     {
      Print("JevDecisionBot: open rejected by threshold (conf=",DoubleToString(conf,2),
            " prob=",DoubleToString(prob,2),")");
      CFileLog::Write(g_outboxFile,TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS)+
                      " JEV open rejected conf="+DoubleToString(conf,2)+" prob="+DoubleToString(prob,2));
      return;
     }
   if(noul<0.5)
     {
      Print("JevDecisionBot: proceed=false -> no open");
      CFileLog::Write(g_outboxFile,TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS)+
                      " JEV proceed="+DoubleToString(noul,2)+" -> no open");
      return;
     }

   // 5. execute (guardrails inside)
   string r=ExecuteCandidate(sym,dir,lot);
   Print("JevDecisionBot: OPEN -> ",r);
   CFileLog::Write(g_outboxFile,TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS)+" "+r);
  }

//+------------------------------------------------------------------+
string ExecuteCandidate(const string sym,const int dir,const double lot)
  {
   return g_tb.ToolOpenOrder(sym,dir,lot,0,0,"JEV");
  }

//+------------------------------------------------------------------+
bool ReadInboxSignal(string &sym,int &dir,double &lot)
  {
   sym=""; dir=0; lot=0;
   int h=FileOpen(g_inboxFile,FILE_READ|FILE_TXT|FILE_ANSI);
   if(h==INVALID_HANDLE) return false;
   string line="";
   while(!FileIsEnding(h))
     {
      string t=FileReadString(h);
      StringTrimRight(t);
      if(t=="") continue;
      line=t;
      break;
     }
   FileClose(h);
   if(line=="") return false;
   // clear inbox
   int w=FileOpen(g_inboxFile,FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(w!=INVALID_HANDLE) FileClose(w);

   string parts[];
   int n=StringSplit(line,' ',parts);
   // format: open|SYMBOL|BUY|LOT
   if(n<4) return false;
   sym=parts[1];
   string sdir=parts[2];
   StringToUpper(sdir);
   dir=0;
   if(sdir!="BUY") dir=1;
   lot=StringToDouble(parts[3]);
   return (sym!="" && lot>0);
  }

//+------------------------------------------------------------------+
string DoLocalSignal(string &sym,int &dir,double &lot)
  {
   sym=InpSymbol;
   // MQL5: indicator functions return handles; use CopyBuffer
   double rsi=0;
   int hRSI=iRSI(sym,PERIOD_H1,14,PRICE_CLOSE);
   double b0[1];
   if(hRSI>=0 && CopyBuffer(hRSI,0,0,1,b0)==1) rsi=b0[0];
   if(hRSI>=0) IndicatorRelease(hRSI);

   double ma20=0;
   int hMA=iMA(sym,PERIOD_H1,20,0,MODE_SMA,PRICE_CLOSE);
   if(hMA>=0 && CopyBuffer(hMA,0,0,1,b0)==1) ma20=b0[0];
   if(hMA>=0) IndicatorRelease(hMA);

   double close=SymbolInfoDouble(sym,SYMBOL_BID);
   if(rsi<30 && close>ma20)
     {
      dir=0; lot=0.1;          // oversold bounce
      return "";
     }
   if(rsi>70 && close<ma20)
     {
      dir=1; lot=0.1;          // overbought pullback
      return "";
     }
   return "no local signal (rsi="+DoubleToString(rsi,1)+")";
  }

//+------------------------------------------------------------------+
string BuildState(void)
  {
   string pos=g_tb.ToolOpenPositions("");
   if(StringLen(pos)>800) pos=StringSubstr(pos,0,800);
   string bars=g_tb.ToolRates(InpSymbol,InpTimeframe,InpBarsCount);
   if(StringLen(bars)>1500) bars=StringSubstr(bars,0,1500);
   string ind=g_tb.ToolIndicators(InpSymbol,InpTimeframe,30);
   if(StringLen(ind)>800) ind=StringSubstr(ind,0,800);

   string s="{";
   s+="\"symbol\":"+CJson::Quote(InpSymbol);
   s+=",\"timeframe\":"+CJson::Quote(InpTimeframe);
   s+=",\"account\":"+CJson::Quote(g_tb.ToolAccountInfo());
   s+=",\"positions\":"+CJson::Quote(pos);
   s+=",\"indicators\":"+CJson::Quote(ind);
   s+=",\"recent_bars\":"+CJson::Quote(bars);
   s+=",\"status\":"+CJson::Quote(g_tb.ToolStatus());
   s+="}";
   return s;
  }

//+------------------------------------------------------------------+
string BuildQuestions(void)
  {
   string q="{";
   q+="\"action\":{\"type\":\"choice\",\"instructions\":"+
     CJson::Quote("Based on the market state, decide the single best trading action for this MT5 account right now.")+
     ",\"criteria\":{\"hold\":"+CJson::Quote("No clear edge; do nothing, keep positions unchanged")+
     ",\"open\":"+CJson::Quote("A high-quality entry exists right now; open a new position")+
     ",\"close\":"+CJson::Quote("Exit current positions to protect capital or take profit")+"}},";
   q+="\"proceed\":{\"type\":\"noul\",\"instructions\":"+
     CJson::Quote("Is it safe and appropriate to place the new trade right now (liquidity, spread, risk, account state)?")+
     ",\"criteria\":{\"true\":"+CJson::Quote("Conditions are safe to trade")+
     ",\"false\":"+CJson::Quote("Something is wrong - avoid trading")+"}}}";
   q+="}";
   return q;
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
   string s="JevDecisionBot v1.20\n";
   s+="model: "+InpModel+"\n";
   s+="poll: "+IntegerToString(InpPollSeconds)+"s\n";
   s+="min conf: "+DoubleToString(InpMinConf,2)+" min prob: "+DoubleToString(InpMinProb,2)+"\n";
   s+="mode: "+(InpSignalMode==1?"inbox":"local")+"\n";
   s+="positions: "+IntegerToString(PositionsTotal())+"\n";
   s+="equity: "+DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY),2);
   ObjectSetString(0,g_panelName,OBJPROP_TEXT,s);
  }

void OnTick(void)
  {
   PanelRefresh();
  }
//+------------------------------------------------------------------+
