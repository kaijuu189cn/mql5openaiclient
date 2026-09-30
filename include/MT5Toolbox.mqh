//+------------------------------------------------------------------+
//|                                           include/MT5Toolbox.mqh |
//|  The "tool bus": every operation the OpenAI model may request    |
//|  through function calling is implemented here, each wrapped with  |
//|  risk guardrails BEFORE it touches the trading engine.           |
//|                                                                  |
//|  Guardrail layers (all enforced locally, never trust the model): |
//|    R1  trading enabled switch                                    |
//|    R2  symbol whitelist                                          |
//|    R3  max lot / max open positions                              |
//|    R4  daily loss limit (closed P/L today + floating)            |
//|    R5  trading session windows                                   |
//|    R6  magic-number isolation                                    |
//|    R7  confirmation / dry-run mode                               |
//|    R8  kill switch                                               |
//+------------------------------------------------------------------+
#ifndef MQL5_OPENAI_MT5TOOLBOX_MQH
#define MQL5_OPENAI_MT5TOOLBOX_MQH

#include "Json.mqh"
#include "Config.mqh"
#include "Timeframes.mqh"

//--- forward declaration (defined at the bottom of this file)
string TradeErrorText(const int e);

enum EToolResult
  {
   TR_OK=0,
   TR_ERROR,          // hard error (bad symbol, invalid lot, ...)
   TR_DENIED,         // guardrail blocked the request
   TR_NEED_CONFIRM,   // confirmation mode: request queued
   TR_PENDING         // async order sent to server
  };

struct SGuardSettings
  {
   bool    tradingEnabled;   // master switch (R1)
   double  maxLot;           // (R3)
   int     maxPositions;     // (R3)
   double  dailyLossLimit;   // in account currency (R4)
   string  sessions;         // "HH:MM-HH:MM,HH:MM-HH:MM" server time (R5)
   string  symbolsWhitelist; // comma separated, "*" = all (R2)
   int     magic;            // (R6)
   bool    confirmMode;      // (R7)
   bool    dryRun;           // (R7)
   bool    killSwitch;       // (R8)
   SGuardSettings()
     {
      tradingEnabled=true;
      maxLot=10.0;
      maxPositions=5;
      dailyLossLimit=1000.0;
      sessions="";
      symbolsWhitelist="*";
      magic=20261030;
      confirmMode=false;
      dryRun=false;
      killSwitch=false;
     }
  };

class CMT5Toolbox
  {
private:
   SGuardSettings m_g;
   string  m_logFile;        // path of the activity log
   string  m_confirmFile;    // path of the confirmation inbox
   string  m_lastTool;       // last tool name
   string  m_lastDetail;     // last detail text

   //--- internal helpers
   bool   SymbolAllowed(const string symbol) const;
   bool   WithinSession(void) const;
   bool   LotWithinLimits(const double lot) const;
   double NormalizeLot(const string symbol,const double lot) const;
   ENUM_ORDER_TYPE_FILLING FillingForSymbol(const string symbol) const;
   double MinStopDistancePoints(const string symbol) const;
   bool   AddLog(const string msg);
   string ToolHeader(void) const;
   double ClosedPLToday(void) const;
   double FloatingPL(void) const;
   string TrimStr(const string s) const;

   //--- guardrail callers (wrapped by tools)
   EToolResult GuardNewPosition(const string symbol,const double lot,string &err) const;
   EToolResult GuardManagePosition(const string symbol,const long ticket,string &err) const;

public:
   CMT5Toolbox(void){}

   void   SetGuard(const SGuardSettings &g){ m_g=g; }
   void   SetLogFile(const string f){ m_logFile=f; }
   void   SetConfirmFile(const string f){ m_confirmFile=f; }
   string LastTool(void) const   { return m_lastTool; }
   string LastDetail(void) const { return m_lastDetail; }

   //=== Market data tools ==========================================
   string ToolSymbolInfo(const string symbol);
   string ToolRates(const string symbol,const string tf,const int count);
   string ToolTicker(const string symbol);
   string ToolIndicators(const string symbol,const string tf,const int count);
   string ToolSymbolsList(void);

   //=== Account tools ==============================================
   string ToolAccountInfo(void);
   string ToolOpenPositions(const string symbol);
   string ToolHistoryToday(void);

   //=== Trading tools (guarded) ====================================
   string ToolOpenOrder(const string symbol,const int dir,const double lot,
                        const double slPoints,const double tpPoints,
                        const string comment);
   string ToolClosePosition(const string symbol,const long ticket,const double lot);
   string ToolCloseAll(const string symbol);
   string ToolModifyPosition(const long ticket,const double slPoints,const double tpPoints);
   string ToolTrailingStop(const long ticket,const double trailPoints);
   string ToolDeletePending(const string symbol,const long ticket);

   //=== Terminal / chart tools =====================================
   string ToolOpenChart(const string symbol,const string tf);
   string ToolChartObject(const string symbol,const string tf,const string kind,
                          const double price,const string text);
   string ToolPopup(const string title,const string msg);
   string ToolLog(const string msg);

   //=== guardrail status / control =================================
   string ToolStatus(void);
   string ToolSetGuard(const string key,const string value);
  };

//+------------------------------------------------------------------+
//| helpers                                                          |
//+------------------------------------------------------------------+
string CMT5Toolbox::TrimStr(const string s) const
  {
   string t=s;
   StringTrimLeft(t);
   StringTrimRight(t);
   return t;
  }

string CMT5Toolbox::ToolHeader(void) const
  {
   return "["+m_lastTool+"] ";
  }

bool CMT5Toolbox::AddLog(const string msg)
  {
   if(m_logFile=="") return false;
   return CFileLog::Write(m_logFile,TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS)+" "+msg);
  }

bool CMT5Toolbox::SymbolAllowed(const string symbol) const
  {
   string w=m_g.symbolsWhitelist;
   StringTrimLeft(w);
   StringTrimRight(w);
   if(w=="*") return true;
   string parts[];
   int n=StringSplit(w,',',parts);
   for(int i=0;i<n;i++)
     {
      string p=parts[i];
      StringTrimLeft(p);
      StringTrimRight(p);
      if(p==symbol) return true;
     }
   return false;
  }

bool CMT5Toolbox::WithinSession(void) const
  {
   if(m_g.sessions=="") return true;
   datetime now=TimeCurrent();
   int cur=(int)(now%86400);
   string parts[];
   int n=StringSplit(m_g.sessions,',',parts);
   for(int i=0;i<n;i++)
     {
      string seg=parts[i];
      int dash=StringFind(seg,"-");
      if(dash<0) continue;
      string a=TrimStr(StringSubstr(seg,0,dash));
      string b=TrimStr(StringSubstr(seg,dash+1));
      int ah=(int)StringToInteger(StringSubstr(a,0,2));
      int am=(int)StringToInteger(StringSubstr(a,3,2));
      int bh=(int)StringToInteger(StringSubstr(b,0,2));
      int bm=(int)StringToInteger(StringSubstr(b,3,2));
      int start=ah*3600+am*60;
      int end=bh*3600+bm*60;
      if(start<=end)
        {
         if(cur>=start && cur<=end) return true;
        }
      else
        {
         // overnight window
         if(cur>=start || cur<=end) return true;
        }
     }
   return false;
  }

double CMT5Toolbox::NormalizeLot(const string symbol,const double lot) const
  {
   double minlot=1.0, maxlot=1000.0, lotstep=0.01;
   if(SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN,minlot)) {}
   if(SymbolInfoDouble(symbol,SYMBOL_VOLUME_MAX,maxlot)) {}
   if(SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP,lotstep)) {}
   if(lotstep<=0) lotstep=0.01;
   double l=MathFloor(lot/lotstep+0.5)*lotstep;
   if(l<minlot) l=minlot;
   if(l>maxlot) l=maxlot;
   return l;
  }

bool CMT5Toolbox::LotWithinLimits(const double lot) const
  {
   if(lot<=0) return false;
   if(m_g.maxLot>0 && lot>m_g.maxLot+1e-9) return false;
   return true;
  }

ENUM_ORDER_TYPE_FILLING CMT5Toolbox::FillingForSymbol(const string symbol) const
  {
   long cm=(long)SymbolInfoInteger(symbol,SYMBOL_FILLING_MODE);
   if((cm & SYMBOL_FILLING_FOK)>0) return ORDER_FILLING_FOK;
   if((cm & SYMBOL_FILLING_IOC)>0) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
  }

double CMT5Toolbox::MinStopDistancePoints(const string symbol) const
  {
   double level=SymbolInfoInteger(symbol,SYMBOL_TRADE_STOPS_LEVEL);
   if(level<0) level=0;
   return level;
  }

double CMT5Toolbox::ClosedPLToday(void) const
  {
   double sum=0;
   datetime now=TimeCurrent();
   datetime dayStart=now-(now%86400);
   if(HistorySelect(dayStart,now))
     {
      int n=HistoryDealsTotal();
      for(int i=0;i<n;i++)
        {
         ulong d=HistoryDealGetTicket(i);
         if(HistoryDealGetInteger(d,DEAL_MAGIC)!=(long)m_g.magic) continue;
         if(HistoryDealGetInteger(d,DEAL_ENTRY)!=DEAL_ENTRY_OUT) continue;
         sum+=HistoryDealGetDouble(d,DEAL_PROFIT)+
              HistoryDealGetDouble(d,DEAL_SWAP)+
              HistoryDealGetDouble(d,DEAL_COMMISSION);
        }
     }
   return sum;
  }

double CMT5Toolbox::FloatingPL(void) const
  {
   double sum=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC)!=(long)m_g.magic) continue;
      sum+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
     }
   return sum;
  }

EToolResult CMT5Toolbox::GuardNewPosition(const string symbol,const double lot,string &err) const
  {
   err="";
   if(!m_g.tradingEnabled){ err="trading disabled (R1)"; return TR_DENIED; }
   if(m_g.killSwitch){ err="kill switch active (R8)"; return TR_DENIED; }
   if(!SymbolAllowed(symbol)){ err="symbol not in whitelist (R2)"; return TR_DENIED; }
   if(!LotWithinLimits(lot))
     { err=StringFormat("lot %.2f exceeds max %.2f (R3)",lot,m_g.maxLot); return TR_DENIED; }
   int open=PositionsTotal();
   if(m_g.maxPositions>0 && open>=m_g.maxPositions)
     { err=StringFormat("max positions %d reached (R3)",m_g.maxPositions); return TR_DENIED; }
   double loss=ClosedPLToday()+FloatingPL();
   if(m_g.dailyLossLimit>0 && loss < -m_g.dailyLossLimit)
     { err=StringFormat("daily loss limit hit (R4): %.2f",loss); return TR_DENIED; }
   if(!WithinSession()){ err="outside trading session (R5)"; return TR_DENIED; }
   return TR_OK;
  }

EToolResult CMT5Toolbox::GuardManagePosition(const string symbol,const long ticket,string &err) const
  {
   err="";
   if(!m_g.tradingEnabled){ err="trading disabled (R1)"; return TR_DENIED; }
   if(m_g.killSwitch){ err="kill switch active (R8)"; return TR_DENIED; }
   if(symbol!="" && !SymbolAllowed(symbol)){ err="symbol not in whitelist (R2)"; return TR_DENIED; }
   if(ticket>0 && PositionSelectByTicket(ticket))
     {
      if(PositionGetInteger(POSITION_MAGIC)!=(long)m_g.magic)
        { err="position has different magic (R6)"; return TR_DENIED; }
     }
   return TR_OK;
  }

//+------------------------------------------------------------------+
//| Market data tools                                                |
//+------------------------------------------------------------------+
string CMT5Toolbox::ToolSymbolInfo(const string symbol)
  {
   m_lastTool="symbol_info";
   if(!SymbolInfoInteger(symbol,SYMBOL_VISIBLE))
     return m_lastTool+"|ERROR|symbol not found: "+symbol;
   string r=m_lastTool+"|OK";
   r+="|digits="+IntegerToString((int)SymbolInfoInteger(symbol,SYMBOL_DIGITS));
   r+="|point="+DoubleToString(SymbolInfoDouble(symbol,SYMBOL_POINT),8);
   r+="|tick_size="+DoubleToString(SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_SIZE),8);
   r+="|tick_value="+DoubleToString(SymbolInfoDouble(symbol,SYMBOL_TRADE_TICK_VALUE),8);
   r+="|contract_size="+DoubleToString(SymbolInfoDouble(symbol,SYMBOL_TRADE_CONTRACT_SIZE),2);
   r+="|volume_min="+DoubleToString(SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN),2);
   r+="|volume_max="+DoubleToString(SymbolInfoDouble(symbol,SYMBOL_VOLUME_MAX),2);
   r+="|volume_step="+DoubleToString(SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP),2);
   r+="|spread="+IntegerToString((int)SymbolInfoInteger(symbol,SYMBOL_SPREAD));
   r+="|trade_mode="+IntegerToString((int)SymbolInfoInteger(symbol,SYMBOL_TRADE_MODE));
   r+="|swap_long="+DoubleToString(SymbolInfoDouble(symbol,SYMBOL_SWAP_LONG),2);
   r+="|swap_short="+DoubleToString(SymbolInfoDouble(symbol,SYMBOL_SWAP_SHORT),2);
   r+="|margin_initial="+DoubleToString(SymbolInfoDouble(symbol,SYMBOL_MARGIN_INITIAL),2);
   r+="|margin_maintenance="+DoubleToString(SymbolInfoDouble(symbol,SYMBOL_MARGIN_MAINTENANCE),2);
   r+="|stops_level="+DoubleToString(SymbolInfoInteger(symbol,SYMBOL_TRADE_STOPS_LEVEL),1);
   r+="|filling_mode="+IntegerToString((int)SymbolInfoInteger(symbol,SYMBOL_FILLING_MODE));
   r+="|time="+TimeToString(SymbolInfoInteger(symbol,SYMBOL_TIME),TIME_DATE|TIME_SECONDS);
   AddLog(ToolHeader()+"queried "+symbol);
   return r;
  }

string CMT5Toolbox::ToolRates(const string symbol,const string tf,const int count)
  {
   m_lastTool="rates";
   ENUM_TIMEFRAMES t=StrToTF(tf);
   if(t==PERIOD_CURRENT) t=PERIOD_M1;
   if(count<=0 || count>1000) count=100;
   MqlRates rt[];
   if(!CopyRates(symbol,t,0,count,rt))
     return m_lastTool+"|ERROR|CopyRates failed: "+IntegerToString(GetLastError());
   int n=ArraySize(rt);
   if(n<=0) return m_lastTool+"|ERROR|no bars";
   int digits=(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
   string r=m_lastTool+"|OK|symbol="+symbol+"|tf="+tf+"|count="+IntegerToString(n)+"\n";
   for(int i=n-1;i>=0;i--)
     {
      r+=TimeToString(rt[i].time,TIME_DATE|TIME_MINUTES)+" O="+
         DoubleToString(rt[i].open,digits)+" H="+
         DoubleToString(rt[i].high,digits)+" L="+
         DoubleToString(rt[i].low,digits)+" C="+
         DoubleToString(rt[i].close,digits)+" V="+
         DoubleToString((double)rt[i].tick_volume,0)+"\n";
     }
   AddLog(ToolHeader()+"queried "+symbol+" "+tf+" x"+IntegerToString(n));
   return r;
  }

string CMT5Toolbox::ToolTicker(const string symbol)
  {
   m_lastTool="ticker";
   if(!SymbolInfoInteger(symbol,SYMBOL_VISIBLE))
     return m_lastTool+"|ERROR|symbol not found: "+symbol;
   double bid=SymbolInfoDouble(symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(symbol,SYMBOL_ASK);
   int digits=(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
   return m_lastTool+"|OK|symbol="+symbol+"|bid="+DoubleToString(bid,digits)+
          "|ask="+DoubleToString(ask,digits);
  }

string CMT5Toolbox::ToolIndicators(const string symbol,const string tf,const int count)
  {
   m_lastTool="indicators";
   ENUM_TIMEFRAMES t=StrToTF(tf);
   if(t==PERIOD_CURRENT) t=PERIOD_M1;
   if(count<=0 || count>1000) count=50;
   if(!SymbolInfoInteger(symbol,SYMBOL_VISIBLE))
     return m_lastTool+"|ERROR|symbol not found: "+symbol;

   int digits=(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
   double ma=iMA(symbol,t,14,0,MODE_SMA,PRICE_CLOSE,0);
   double rsi=iRSI(symbol,t,14,PRICE_CLOSE,0);
   double atr=iATR(symbol,t,14,0);
   double macd_main=iMACD(symbol,t,12,26,9,PRICE_CLOSE,MODE_MAIN,0);
   double macd_sig=iMACD(symbol,t,12,26,9,PRICE_CLOSE,MODE_SIGNAL,0);
   double macd_hist=macd_main-macd_sig;
   double bb_mid=iBands(symbol,t,20,2,0,PRICE_CLOSE,MODE_MAIN,0);
   double bb_up=iBands(symbol,t,20,2,0,PRICE_CLOSE,MODE_UPPER,0);
   double bb_lo=iBands(symbol,t,20,2,0,PRICE_CLOSE,MODE_LOWER,0);
   double st_k=iStochastic(symbol,t,5,3,3,MODE_SMA,0,MODE_MAIN,0);
   double st_d=iStochastic(symbol,t,5,3,3,MODE_SMA,0,MODE_SIGNAL,0);

   string r=m_lastTool+"|OK|symbol="+symbol+"|tf="+tf;
   r+="|MA14="+DoubleToString(ma,digits);
   r+="|RSI14="+DoubleToString(rsi,2);
   r+="|ATR14="+DoubleToString(atr,digits);
   r+="|MACD="+DoubleToString(macd_main,5)+"|MACDsig="+DoubleToString(macd_sig,5)+
      "|MACDhist="+DoubleToString(macd_hist,5);
   r+="|BB_mid="+DoubleToString(bb_mid,digits)+"|BB_up="+DoubleToString(bb_up,digits)+
      "|BB_lo="+DoubleToString(bb_lo,digits);
   r+="|StochK="+DoubleToString(st_k,2)+"|StochD="+DoubleToString(st_d,2);

   MqlRates rt[];
   if(CopyRates(symbol,t,0,count,rt))
     {
      int n=ArraySize(rt);
      r+="\ncloses:";
      for(int i=n-1;i>=0;i--)
         r+=" "+DoubleToString(rt[i].close,digits);
     }
   AddLog(ToolHeader()+"queried "+symbol+" "+tf);
   return r;
  }

string CMT5Toolbox::ToolSymbolsList(void)
  {
   m_lastTool="symbols_list";
   int total=SymbolsTotal(false);
   string r=m_lastTool+"|OK|count="+IntegerToString(total);
   for(int i=0;i<total;i++)
     {
      string s=SymbolName(i,false);
      if(SymbolInfoInteger(s,SYMBOL_VISIBLE))
         r+="\n"+s;
     }
   return r;
  }

//+------------------------------------------------------------------+
//| Account tools                                                    |
//+------------------------------------------------------------------+
string CMT5Toolbox::ToolAccountInfo(void)
  {
   m_lastTool="account_info";
   string r=m_lastTool+"|OK";
   r+="|login="+IntegerToString((int)AccountInfoInteger(ACCOUNT_LOGIN));
   r+="|server="+AccountInfoString(ACCOUNT_SERVER);
   r+="|name="+AccountInfoString(ACCOUNT_NAME);
   r+="|currency="+AccountInfoString(ACCOUNT_CURRENCY);
   r+="|balance="+DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2);
   r+="|equity="+DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY),2);
   r+="|margin="+DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN),2);
   r+="|free_margin="+DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE),2);
   r+="|margin_level="+DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_LEVEL),2);
   r+="|leverage="+IntegerToString((int)AccountInfoInteger(ACCOUNT_LEVERAGE));
   r+="|trade_allowed="+IntegerToString((int)AccountInfoInteger(ACCOUNT_TRADE_ALLOWED));
   r+="|trade_expert="+IntegerToString((int)AccountInfoInteger(ACCOUNT_TRADE_EXPERT));
   return r;
  }

string CMT5Toolbox::ToolOpenPositions(const string symbol)
  {
   m_lastTool="open_positions";
   int shown=0;
   string r=m_lastTool+"|OK";
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC)!=(long)m_g.magic) continue;
      string s=PositionGetString(POSITION_SYMBOL);
      if(symbol!="" && s!=symbol) continue;
      long type=PositionGetInteger(POSITION_TYPE);
      string dir=(type==POSITION_TYPE_BUY)?"BUY":"SELL";
      r+=StringFormat("\n#%s %s %s %.2f @ %.5f SL=%.5f TP=%.5f profit=%.2f",
                      IntegerToString(t),dir,s,
                      PositionGetDouble(POSITION_VOLUME),
                      PositionGetDouble(POSITION_PRICE_OPEN),
                      PositionGetDouble(POSITION_SL),
                      PositionGetDouble(POSITION_TP),
                      PositionGetDouble(POSITION_PROFIT));
      shown++;
     }
   r+="\nshown="+IntegerToString(shown);
   return r;
  }

string CMT5Toolbox::ToolHistoryToday(void)
  {
   m_lastTool="history_today";
   datetime now=TimeCurrent();
   datetime dayStart=now-(now%86400);
   if(!HistorySelect(dayStart,now))
     return m_lastTool+"|ERROR|HistorySelect failed: "+IntegerToString(GetLastError());
   int n=HistoryDealsTotal();
   int shown=0;
   double p=0;
   string r=m_lastTool+"|OK|deals="+IntegerToString(n);
   for(int i=0;i<n;i++)
     {
      ulong d=HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(d,DEAL_MAGIC)!=(long)m_g.magic) continue;
      long type=HistoryDealGetInteger(d,DEAL_TYPE);
      string ts=(type==DEAL_TYPE_BUY)?"BUY":(type==DEAL_TYPE_SELL)?"SELL":
                (type==DEAL_TYPE_BUY_LIMIT)?"BUY_LIMIT":(type==DEAL_TYPE_SELL_LIMIT)?"SELL_LIMIT":
                (type==DEAL_TYPE_BUY_STOP)?"BUY_STOP":(type==DEAL_TYPE_SELL_STOP)?"SELL_STOP":"OTHER";
      double profit=HistoryDealGetDouble(d,DEAL_PROFIT)+
                    HistoryDealGetDouble(d,DEAL_SWAP)+
                    HistoryDealGetDouble(d,DEAL_COMMISSION);
      p+=profit;
      r+=StringFormat("\n%s %s %s %.2f @ %.5f profit=%.2f",
                      TimeToString(HistoryDealGetInteger(d,DEAL_TIME),TIME_DATE|TIME_MINUTES),
                      ts,
                      HistoryDealGetString(d,DEAL_SYMBOL),
                      HistoryDealGetDouble(d,DEAL_VOLUME),
                      HistoryDealGetDouble(d,DEAL_PRICE),
                      profit);
      shown++;
     }
   r+=StringFormat("\nshown=%d total_pl=%.2f",shown,p);
   return r;
  }

//+------------------------------------------------------------------+
//| Trading tools (guarded)                                          |
//+------------------------------------------------------------------+
string CMT5Toolbox::ToolOpenOrder(const string symbol,const int dir,const double lot,
                                  const double slPoints,const double tpPoints,
                                  const string comment)
  {
   m_lastTool="open_order";
   string err="";
   EToolResult g=GuardNewPosition(symbol,lot,err);
   if(g==TR_DENIED) return m_lastTool+"|DENIED|"+err;
   if(g!=TR_OK)     return m_lastTool+"|ERROR|"+err;
   if(dir!=POSITION_TYPE_BUY && dir!=POSITION_TYPE_SELL)
     return m_lastTool+"|ERROR|dir must be 0(BUY) or 1(SELL)";
   if(!SymbolInfoInteger(symbol,SYMBOL_VISIBLE))
     return m_lastTool+"|ERROR|symbol not found: "+symbol;

   double point=SymbolInfoDouble(symbol,SYMBOL_POINT);
   double price=0, sl=0, tp=0;
   if(dir==POSITION_TYPE_BUY)
     {
      price=SymbolInfoDouble(symbol,SYMBOL_ASK);
      if(slPoints>0) sl=price-slPoints*point;
      if(tpPoints>0) tp=price+tpPoints*point;
     }
   else
     {
      price=SymbolInfoDouble(symbol,SYMBOL_BID);
      if(slPoints>0) sl=price+slPoints*point;
      if(tpPoints>0) tp=price-tpPoints*point;
     }

   // clamp SL/TP to the broker stop level
   double minDist=MinStopDistancePoints(symbol)*point;
   if(slPoints>0 && minDist>0 && slPoints*point<minDist)
      sl=(dir==POSITION_TYPE_BUY)?price-minDist:price+minDist;
   if(tpPoints>0 && minDist>0 && tpPoints*point<minDist)
      tp=(dir==POSITION_TYPE_BUY)?price+minDist:price-minDist;

   double vol=NormalizeLot(symbol,lot);
   string dirText=(dir==POSITION_TYPE_BUY)?"BUY":"SELL";

   if(m_g.dryRun)
     {
      string out=m_lastTool+"|DRYRUN|would open "+dirText+" "+DoubleToString(vol,2)+" "+symbol+
                 " @ "+DoubleToString(price,(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS))+
                 " SL="+DoubleToString(sl,(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS))+
                 " TP="+DoubleToString(tp,(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS));
      AddLog(ToolHeader()+"DRYRUN "+symbol+" "+dirText+" "+DoubleToString(vol,2));
      return out;
     }

   if(m_g.confirmMode)
     {
      string req=StringFormat("open|%s|%d|%.2f|%.1f|%.1f|%s",
                              symbol,dir,lot,slPoints,tpPoints,comment);
      if(CFileLog::Write(m_confirmFile,req))
        {
         AddLog(ToolHeader()+"confirmation requested: "+req);
         return m_lastTool+"|NEED_CONFIRM|"+req;
        }
      return m_lastTool+"|ERROR|cannot write confirm file";
     }

   MqlTradeRequest req={0};
   MqlTradeResult res={0};
   req.action=TRADE_ACTION_DEAL;
   req.symbol=symbol;
   req.volume=vol;
   req.type=(dir==POSITION_TYPE_BUY)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   req.price=price;
   req.sl=sl;
   req.tp=tp;
   req.deviation=20;
   req.magic=m_g.magic;
   req.comment=(comment!="")?comment:"OpenAI";
   req.type_filling=FillingForSymbol(symbol);

   ResetLastError();
   if(!OrderSend(req,res))
     {
      int e=GetLastError();
      AddLog(ToolHeader()+"failed "+symbol+" err="+IntegerToString(e));
      return m_lastTool+"|ERROR|OrderSend failed ("+IntegerToString(e)+"): "+TradeErrorText(e);
     }
   AddLog(ToolHeader()+"opened "+dirText+" "+symbol+
          " lot="+DoubleToString(req.volume,2)+" ticket="+IntegerToString((int)res.order));
   return m_lastTool+"|OK|deal="+IntegerToString((int)res.deal)+
          "|ticket="+IntegerToString((int)res.order)+"|volume="+DoubleToString(res.volume,2);
  }

string CMT5Toolbox::ToolClosePosition(const string symbol,const long ticket,const double lot)
  {
   m_lastTool="close_position";
   if(ticket<=0)
     {
      // close by symbol (first matching own-magic position)
      for(int i=PositionsTotal()-1;i>=0;i--)
        {
         ulong t=PositionGetTicket(i);
         if(PositionGetInteger(POSITION_MAGIC)!=(long)m_g.magic) continue;
         if(symbol!="" && PositionGetString(POSITION_SYMBOL)!=symbol) continue;
         return ToolClosePosition("",(long)t,0);
        }
      return m_lastTool+"|ERROR|no matching position";
     }
   string err="";
   EToolResult g=GuardManagePosition(symbol,ticket,err);
   if(g==TR_DENIED) return m_lastTool+"|DENIED|"+err;
   if(g!=TR_OK)     return m_lastTool+"|ERROR|"+err;
   if(!PositionSelectByTicket(ticket))
     return m_lastTool+"|ERROR|position not found: "+IntegerToString((int)ticket);

   string sym=PositionGetString(POSITION_SYMBOL);
   double vol=PositionGetDouble(POSITION_VOLUME);
   if(lot>0 && lot<vol) vol=lot;   // partial close
   long ptype=PositionGetInteger(POSITION_TYPE);
   int digits=(int)SymbolInfoInteger(sym,SYMBOL_DIGITS);

   if(m_g.dryRun)
     {
      AddLog(ToolHeader()+"DRYRUN close #"+IntegerToString((int)ticket));
      return m_lastTool+"|DRYRUN|would close #"+IntegerToString((int)ticket)+" "+sym+" "+DoubleToString(vol,2);
     }
   if(m_g.confirmMode)
     {
      string req="close|"+IntegerToString((int)ticket)+"|"+DoubleToString(vol,2);
      if(CFileLog::Write(m_confirmFile,req))
        {
         AddLog(ToolHeader()+"confirmation requested: "+req);
         return m_lastTool+"|NEED_CONFIRM|"+req;
        }
      return m_lastTool+"|ERROR|cannot write confirm file";
     }

   MqlTradeRequest req={0};
   MqlTradeResult res={0};
   req.action=TRADE_ACTION_DEAL;
   req.symbol=sym;
   req.volume=vol;
   req.position=ticket;
   req.type=(ptype==POSITION_TYPE_BUY)?ORDER_TYPE_SELL:ORDER_TYPE_BUY;
   req.price=(ptype==POSITION_TYPE_BUY)?SymbolInfoDouble(sym,SYMBOL_BID):
                                         SymbolInfoDouble(sym,SYMBOL_ASK);
   req.deviation=20;
   req.magic=m_g.magic;
   req.comment="OpenAI-close";
   req.type_filling=FillingForSymbol(sym);

   ResetLastError();
   if(!OrderSend(req,res))
     {
      int e=GetLastError();
      AddLog(ToolHeader()+"close failed #"+IntegerToString((int)ticket)+" err="+IntegerToString(e));
      return m_lastTool+"|ERROR|OrderSend failed ("+IntegerToString(e)+"): "+TradeErrorText(e);
     }
   AddLog(ToolHeader()+"closed #"+IntegerToString((int)ticket)+" "+sym+" "+DoubleToString(vol,2));
   return m_lastTool+"|OK|deal="+IntegerToString((int)res.deal)+"|volume="+DoubleToString(res.volume,2);
  }

string CMT5Toolbox::ToolCloseAll(const string symbol)
  {
   m_lastTool="close_all";
   string err="";
   EToolResult g=GuardManagePosition(symbol,0,err);
   if(g==TR_DENIED) return m_lastTool+"|DENIED|"+err;
   if(g!=TR_OK)     return m_lastTool+"|ERROR|"+err;
   if(m_g.confirmMode)
     {
      string req="closeall|"+symbol;
      if(CFileLog::Write(m_confirmFile,req))
        {
         AddLog(ToolHeader()+"confirmation requested: "+req);
         return m_lastTool+"|NEED_CONFIRM|"+req;
        }
      return m_lastTool+"|ERROR|cannot write confirm file";
     }
   int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
     {
      ulong t=PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC)!=(long)m_g.magic) continue;
      string s=PositionGetString(POSITION_SYMBOL);
      if(symbol!="" && s!=symbol) continue;
      string r=ToolClosePosition("",(long)t,0);
      if(StringFind(r,"|OK|")>=0) n++;
     }
   return m_lastTool+"|OK|closed="+IntegerToString(n);
  }

string CMT5Toolbox::ToolModifyPosition(const long ticket,const double slPoints,const double tpPoints)
  {
   m_lastTool="modify_position";
   if(ticket<=0) return m_lastTool+"|ERROR|ticket required";
   string err="";
   EToolResult g=GuardManagePosition("",ticket,err);
   if(g==TR_DENIED) return m_lastTool+"|DENIED|"+err;
   if(g!=TR_OK)     return m_lastTool+"|ERROR|"+err;
   if(!PositionSelectByTicket(ticket))
     return m_lastTool+"|ERROR|position not found";

   string sym=PositionGetString(POSITION_SYMBOL);
   long ptype=PositionGetInteger(POSITION_TYPE);
   double open=PositionGetDouble(POSITION_PRICE_OPEN);
   double point=SymbolInfoDouble(sym,SYMBOL_POINT);
   int digits=(int)SymbolInfoInteger(sym,SYMBOL_DIGITS);
   double sl=PositionGetDouble(POSITION_SL);
   double tp=PositionGetDouble(POSITION_TP);
   // slPoints/tpPoints: >=0 means set (0 = clear), <0 means keep unchanged
   if(slPoints>=0) sl=(ptype==POSITION_TYPE_BUY)?open-slPoints*point:open+slPoints*point;
   if(tpPoints>=0) tp=(ptype==POSITION_TYPE_BUY)?open+tpPoints*point:open-tpPoints*point;

   MqlTradeRequest req={0};
   MqlTradeResult res={0};
   req.action=TRADE_ACTION_SLTP;
   req.symbol=sym;
   req.position=ticket;
   req.sl=sl;
   req.tp=tp;
   req.magic=m_g.magic;

   ResetLastError();
   if(!OrderSend(req,res))
     {
      int e=GetLastError();
      AddLog(ToolHeader()+"modify failed #"+IntegerToString((int)ticket)+" err="+IntegerToString(e));
      return m_lastTool+"|ERROR|OrderSend failed ("+IntegerToString(e)+"): "+TradeErrorText(e);
     }
   AddLog(ToolHeader()+"modified #"+IntegerToString((int)ticket)+" SL="+DoubleToString(sl,digits)+
          " TP="+DoubleToString(tp,digits));
   return m_lastTool+"|OK|SL="+DoubleToString(sl,digits)+"|TP="+DoubleToString(tp,digits);
  }

string CMT5Toolbox::ToolTrailingStop(const long ticket,const double trailPoints)
  {
   m_lastTool="trailing_stop";
   if(ticket<=0) return m_lastTool+"|ERROR|ticket required";
   if(trailPoints<=0) return m_lastTool+"|ERROR|trailPoints must be > 0";
   string err="";
   EToolResult g=GuardManagePosition("",ticket,err);
   if(g==TR_DENIED) return m_lastTool+"|DENIED|"+err;
   if(g!=TR_OK)     return m_lastTool+"|ERROR|"+err;
   if(!PositionSelectByTicket(ticket))
     return m_lastTool+"|ERROR|position not found";

   string sym=PositionGetString(POSITION_SYMBOL);
   long ptype=PositionGetInteger(POSITION_TYPE);
   double point=SymbolInfoDouble(sym,SYMBOL_POINT);
   int digits=(int)SymbolInfoInteger(sym,SYMBOL_DIGITS);
   double curPrice=(ptype==POSITION_TYPE_BUY)?SymbolInfoDouble(sym,SYMBOL_BID):
                                              SymbolInfoDouble(sym,SYMBOL_ASK);
   double oldSL=PositionGetDouble(POSITION_SL);
   double newSL=(ptype==POSITION_TYPE_BUY)?curPrice-trailPoints*point:
                                           curPrice+trailPoints*point;
   // never move the stop backwards
   if(ptype==POSITION_TYPE_BUY && oldSL>0 && newSL<oldSL) newSL=oldSL;
   if(ptype==POSITION_TYPE_SELL && oldSL>0 && newSL>oldSL) newSL=oldSL;

   MqlTradeRequest req={0};
   MqlTradeResult res={0};
   req.action=TRADE_ACTION_SLTP;
   req.symbol=sym;
   req.position=ticket;
   req.sl=newSL;
   req.tp=PositionGetDouble(POSITION_TP);
   req.magic=m_g.magic;

   ResetLastError();
   if(!OrderSend(req,res))
     {
      int e=GetLastError();
      AddLog(ToolHeader()+"trailing failed #"+IntegerToString((int)ticket)+" err="+IntegerToString(e));
      return m_lastTool+"|ERROR|OrderSend failed ("+IntegerToString(e)+"): "+TradeErrorText(e);
     }
   AddLog(ToolHeader()+"trailed #"+IntegerToString((int)ticket)+" SL="+DoubleToString(newSL,digits));
   return m_lastTool+"|OK|SL="+DoubleToString(newSL,digits);
  }

string CMT5Toolbox::ToolDeletePending(const string symbol,const long ticket)
  {
   m_lastTool="delete_pending";
   string err="";
   EToolResult g=GuardManagePosition(symbol,0,err);
   if(g==TR_DENIED) return m_lastTool+"|DENIED|"+err;
   if(g!=TR_OK)     return m_lastTool+"|ERROR|"+err;
   if(ticket<=0) return m_lastTool+"|ERROR|ticket required";
   if(!OrderSelect(ticket))
     return m_lastTool+"|ERROR|order not found";
   if(OrderGetInteger(ORDER_MAGIC)!=(long)m_g.magic)
     return m_lastTool+"|DENIED|order has different magic (R6)";

   MqlTradeRequest req={0};
   MqlTradeResult res={0};
   req.action=TRADE_ACTION_REMOVE;
   req.order=ticket;

   ResetLastError();
   if(!OrderSend(req,res))
     {
      int e=GetLastError();
      AddLog(ToolHeader()+"delete pending failed #"+IntegerToString((int)ticket)+" err="+IntegerToString(e));
      return m_lastTool+"|ERROR|OrderSend failed ("+IntegerToString(e)+"): "+TradeErrorText(e);
     }
   AddLog(ToolHeader()+"deleted pending #"+IntegerToString((int)ticket));
   return m_lastTool+"|OK|deleted "+IntegerToString((int)ticket);
  }

//+------------------------------------------------------------------+
//| Terminal / chart tools                                           |
//+------------------------------------------------------------------+
string CMT5Toolbox::ToolOpenChart(const string symbol,const string tf)
  {
   m_lastTool="open_chart";
   ENUM_TIMEFRAMES t=StrToTF(tf);
   if(t==PERIOD_CURRENT) t=PERIOD_H1;
   if(!ChartOpen(symbol,t))
     return m_lastTool+"|ERROR|ChartOpen failed ("+IntegerToString(GetLastError())+")";
   AddLog(ToolHeader()+"opened chart "+symbol+" "+tf);
   return m_lastTool+"|OK|"+symbol+"|"+tf;
  }

string CMT5Toolbox::ToolChartObject(const string symbol,const string tf,const string kind,
                                    const double price,const string text)
  {
   m_lastTool="chart_object";
   long chart=ChartFirst();
   if(chart<=0) return m_lastTool+"|ERROR|no chart open";
   string objName="OpenAI_"+kind+"_"+IntegerToString((int)chart)+"_"+IntegerToString((int)TimeCurrent());
   bool ok=false;
   if(kind=="hline")
      ok=ObjectCreate(chart,objName,OBJ_HLINE,0,0,price);
   else if(kind=="vline")
      ok=ObjectCreate(chart,objName,OBJ_VLINE,0,TimeCurrent(),0);
   else if(kind=="text")
     {
      ok=ObjectCreate(chart,objName,OBJ_TEXT,0,TimeCurrent(),price);
      if(ok) ObjectSetString(chart,objName,OBJPROP_TEXT,text);
     }
   else if(kind=="label")
     {
      ok=ObjectCreate(chart,objName,OBJ_LABEL,0,0,0);
      if(ok)
        {
         ObjectSetInteger(chart,objName,OBJPROP_CORNER,CORNER_LEFT_UPPER);
         ObjectSetInteger(chart,objName,OBJPROP_XDISTANCE,20);
         ObjectSetInteger(chart,objName,OBJPROP_YDISTANCE,40);
         ObjectSetString(chart,objName,OBJPROP_TEXT,text);
        }
     }
   else if(kind=="arrow")
     {
      ok=ObjectCreate(chart,objName,OBJ_ARROW,0,TimeCurrent(),price);
      if(ok) ObjectSetInteger(chart,objName,OBJPROP_ARROWCODE,233);   // up arrow
     }
   else if(kind=="delete")
      return m_lastTool+"|OK|(no delete)";

   if(!ok) return m_lastTool+"|ERROR|ObjectCreate failed ("+IntegerToString(GetLastError())+")";
   ObjectSetInteger(chart,objName,OBJPROP_COLOR,clrDodgerBlue);
   ObjectSetInteger(chart,objName,OBJPROP_WIDTH,2);
   return m_lastTool+"|OK|"+objName;
  }

string CMT5Toolbox::ToolPopup(const string title,const string msg)
  {
   m_lastTool="popup";
   Alert(title+" : "+msg);
   AddLog(ToolHeader()+title+" : "+msg);
   return m_lastTool+"|OK|shown";
  }

string CMT5Toolbox::ToolLog(const string msg)
  {
   m_lastTool="log";
   Print("OpenAI: "+msg);
   AddLog(ToolHeader()+msg);
   return m_lastTool+"|OK|logged";
  }

//+------------------------------------------------------------------+
//| Guardrail status / control                                       |
//+------------------------------------------------------------------+
string CMT5Toolbox::ToolStatus(void)
  {
   m_lastTool="status";
   string r=m_lastTool+"|OK";
   r+="|trading="+((m_g.tradingEnabled)?"on":"off");
   r+="|kill="+((m_g.killSwitch)?"on":"off");
   r+="|max_lot="+DoubleToString(m_g.maxLot,2);
   r+="|max_pos="+IntegerToString(m_g.maxPositions);
   r+="|daily_loss_limit="+DoubleToString(m_g.dailyLossLimit,2);
   r+="|sessions="+((m_g.sessions=="")?"24/7":m_g.sessions);
   r+="|whitelist="+m_g.symbolsWhitelist;
   r+="|magic="+IntegerToString(m_g.magic);
   r+="|confirm_mode="+((m_g.confirmMode)?"on":"off");
   r+="|dry_run="+((m_g.dryRun)?"on":"off");
   r+="|open_positions="+IntegerToString(PositionsTotal());
   r+="|equity="+DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY),2);
   r+="|free_margin="+DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE),2);
   r+="|day_pl="+DoubleToString(ClosedPLToday()+FloatingPL(),2);
   return r;
  }

string CMT5Toolbox::ToolSetGuard(const string key,const string value)
  {
   m_lastTool="set_guard";
   string k=key;
   StringToLower(k);
   bool on=(value=="1" || value=="true" || value=="on");
   if(k=="trading")
      m_g.tradingEnabled=on;
   else if(k=="kill")
      m_g.killSwitch=on;
   else if(k=="max_lot")
      m_g.maxLot=MathMax(0,MathMin(1000,StringToDouble(value)));
   else if(k=="max_positions")
      m_g.maxPositions=(int)MathMax(0,MathMin(1000,StringToInteger(value)));
   else if(k=="daily_loss_limit")
      m_g.dailyLossLimit=MathMax(0,StringToDouble(value));
   else if(k=="sessions")
      m_g.sessions=value;
   else if(k=="whitelist")
      m_g.symbolsWhitelist=value;
   else if(k=="confirm_mode")
      m_g.confirmMode=on;
   else if(k=="dry_run")
      m_g.dryRun=on;
   else
      return m_lastTool+"|ERROR|unknown guard key: "+key;
   AddLog(ToolHeader()+key+"="+value);
   return m_lastTool+"|OK|"+key+"="+value;
  }

//+------------------------------------------------------------------+
//| trade error text                                                 |
//+------------------------------------------------------------------+
string TradeErrorText(const int e)
  {
   switch(e)
     {
      case 10004: return "REQUOTE";
      case 10006: return "REJECT";
      case 10007: return "CANCEL";
      case 10008: return "PLACED";
      case 10009: return "DONE";
      case 10010: return "DONE_PARTIAL";
      case 10011: return "ERROR";
      case 10012: return "TIMEOUT";
      case 10013: return "INVALID";
      case 10014: return "INVALID_VOLUME";
      case 10015: return "INVALID_PRICE";
      case 10016: return "INVALID_STOPS";
      case 10017: return "TRADE_DISABLED";
      case 10018: return "MARKET_CLOSED";
      case 10019: return "NO_MONEY";
      case 10020: return "PRICE_CHANGED";
      case 10021: return "PRICE_OFF";
      case 10022: return "INVALID_EXPIRATION";
      case 10023: return "ORDER_CHANGED";
      case 10024: return "TOO_MANY_REQUESTS";
      case 10025: return "NO_CHANGES";
      case 10026: return "SERVER_DISABLED_AT";
      case 10027: return "CLIENT_DISABLED_AT";
      case 10028: return "LOCKED";
      case 10029: return "FROZEN";
      case 10030: return "INVALID_FILL";
      case 10031: return "CONNECTION";
      case 10032: return "REQUOTE_FILED";
      case 10033: return "STOP_DISABLED";
      case 10034: return "TRADE_HEDGE_PROHIBITED";
      case 10035: return "TRADE_EXPERT_DISABLED";
      default:    return "UNKNOWN("+IntegerToString(e)+")";
     }
  }

#endif // MQL5_OPENAI_MT5TOOLBOX_MQH
