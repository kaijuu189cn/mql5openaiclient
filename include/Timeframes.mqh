//+------------------------------------------------------------------+
//|                                            include/Timeframes.mqh |
//|  Timeframe-string helper: "m1","m5","m15","m30","h1","h4","d1",  |
//|  "w1","mn1" -> ENUM_TIMEFRAMES. Returns PERIOD_CURRENT on no     |
//|  match (callers replace it with a safe default).                 |
//+------------------------------------------------------------------+
#ifndef MQL5_OPENAI_TIMEFRAMES_MQH
#define MQL5_OPENAI_TIMEFRAMES_MQH

ENUM_TIMEFRAMES StrToTF(const string tf)
  {
   string t=tf;
   StringToLower(t);
   StringTrimLeft(t);
   StringTrimRight(t);
   if(t=="m1"  || t=="1m")  return PERIOD_M1;
   if(t=="m5"  || t=="5m")  return PERIOD_M5;
   if(t=="m15" || t=="15m") return PERIOD_M15;
   if(t=="m30" || t=="30m") return PERIOD_M30;
   if(t=="h1"  || t=="1h"  || t=="h")  return PERIOD_H1;
   if(t=="h2"  || t=="2h")  return PERIOD_H2;
   if(t=="h4"  || t=="4h")  return PERIOD_H4;
   if(t=="h6"  || t=="6h")  return PERIOD_H6;
   if(t=="h8"  || t=="8h")  return PERIOD_H8;
   if(t=="h12" || t=="12h") return PERIOD_H12;
   if(t=="d1"  || t=="1d"  || t=="d")  return PERIOD_D1;
   if(t=="w1"  || t=="1w"  || t=="w")  return PERIOD_W1;
   if(t=="mn1" || t=="mn"  || t=="1mn") return PERIOD_MN1;
   return PERIOD_CURRENT;
  }

string TFToStr(const ENUM_TIMEFRAMES tf)
  {
   switch(tf)
     {
      case PERIOD_M1:  return "M1";
      case PERIOD_M5:  return "M5";
      case PERIOD_M15: return "M15";
      case PERIOD_M30: return "M30";
      case PERIOD_H1:  return "H1";
      case PERIOD_H2:  return "H2";
      case PERIOD_H4:  return "H4";
      case PERIOD_H6:  return "H6";
      case PERIOD_H8:  return "H8";
      case PERIOD_H12: return "H12";
      case PERIOD_D1:  return "D1";
      case PERIOD_W1:  return "W1";
      case PERIOD_MN1: return "MN1";
      default:         return "CURRENT";
     }
  }

#endif // MQL5_OPENAI_TIMEFRAMES_MQH
