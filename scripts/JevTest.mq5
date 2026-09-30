//+------------------------------------------------------------------+
//|                                    scripts/JevTest.mq5            |
//|  Standalone test for the JEV Decisions API (OpenRouter).         |
//|  Sends a tiny choice + noul question; prints the typed answers   |
//|  with probabilities. No trading.                                 |
//|  Run this FIRST to verify API key + WebRequest whitelist.        |
//+------------------------------------------------------------------+
#property copyright "MQL5-OpenAI"
#property version   "1.00"
#property strict

#include "..\include\JevClient.mqh"
#include "..\include\Json.mqh"

input string InpApiKey  = "";                     // OpenRouter API key (sk-or-...)
input string InpBaseUrl = "https://openrouter.ai"; // base URL
input string InpModel   = "typesafe/jev-1.13";    // model
input int    InpTimeout = 30000;

//+------------------------------------------------------------------+
void OnStart(void)
  {
   if(InpApiKey=="")
     {
      Print("JevTest: please set the API key input and run again.");
      return;
     }
   CJevClient jev;
   jev.Setup(InpApiKey,InpBaseUrl,InpModel);

   string state="{\"market\":\"EURUSD H1, price 1.0850, RSI 62, uptrend, "+
                "no open positions, account equity 10000\"}";
   string questions="{";
   questions+="\"action\":{\"type\":\"choice\",\"instructions\":\"What should the bot do?\",";
   questions+="\"criteria\":{\"hold\":\"Do nothing\",\"buy\":\"Open a buy\",\"sell\":\"Open a sell\"}}},";
   questions+="\"safe\":{\"type\":\"noul\",\"instructions\":\"Is it safe to trade now?\",";
   questions+="\"criteria\":{\"true\":\"Yes\",\"false\":\"No\"}}}";
   questions+="}";

   datetime t0=GetTickCount();
   bool ok=jev.Decide(state,questions);
   int ms=(int)(GetTickCount()-t0);
   if(!ok)
     {
      string msg="JevTest: FAILED - "+jev.LastError();
      Print(msg);
      Print("JevTest: check Tools->Options->Expert Advisors->Allow WebRequest for https://openrouter.ai");
      FileWriteLog(msg);
      return;
     }
   string action=jev.ChoiceValue("action");
   double conf=jev.ChoiceConfidence("action");
   double p=jev.ChoiceProbability("action",action);
   double safe=jev.NoulValue("safe");
   string txt=StringFormat("JevTest: OK in %d ms | action=%s prob=%.2f conf=%.2f | safe=%.2f",
                           ms,action,p,conf,safe);
   Print(txt);
   Print("JevTest: raw answers: ",jev.RawAnswers());
   FileWriteLog(txt);
  }

//+------------------------------------------------------------------+
void FileWriteLog(const string msg)
  {
   int h=FileOpen("JevTest.txt",FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(h==INVALID_HANDLE) return;
   FileWriteString(h,msg+"\r\n");
   FileClose(h);
  }
//+------------------------------------------------------------------+
