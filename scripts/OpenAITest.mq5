//+------------------------------------------------------------------+
//|                                   scripts/OpenAITest.mq5          |
//|  Standalone connectivity + latency test for the OpenAI endpoint. |
//|  Sends one minimal chat request (no tools, no trading).          |
//|  Use this FIRST to verify whitelist + API key before running the |
//|  EA. Output goes to the Experts log and a file OpenAITest.txt.   |
//+------------------------------------------------------------------+
#property copyright "MQL5-OpenAI"
#property version   "1.00"
#property strict

#include <HttpClient.mqh>
#include <Json.mqh>

//--- inputs
input string InpApiKey  = "";                          // OpenAI API key
input string InpBaseUrl = "https://api.openai.com/v1"; // base URL
input string InpModel   = "gpt-4o-mini";               // model
input int    InpTimeout = 30000;                       // timeout ms

//+------------------------------------------------------------------+
void OnStart(void)
  {
   if(InpApiKey=="")
     {
      Print("OpenAITest: please set the API key input and run again.");
      return;
     }
   CHttpClient http;
   string body="{\"model\":"+CJson::Quote(InpModel)+
               ",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],"+
               "\"max_tokens\":5}";
   string headers="Authorization: Bearer "+InpApiKey+
                  "\r\nContent-Type: application/json";
   string url=InpBaseUrl+"/chat/completions";
   if(StringGetCharacter(url,StringLen(url)-1)=='/')
      url=StringSubstr(url,0,StringLen(url)-1);

   string resp="", respHeaders="";
   datetime t0=GetTickCount();
   int code=http.PostJson(url,headers,body,InpTimeout,resp,respHeaders);
   int ms=(int)(GetTickCount()-t0);
   if(code<0)
     {
      string msg="OpenAITest: FAILED - "+http.LastError();
      Print(msg);
      Print("OpenAITest: check Tools->Options->Expert Advisors->Allow WebRequest for: ",url);
      FileWriteLog(msg);
      return;
     }
   string txt="OpenAITest: HTTP "+IntegerToString(code)+" in "+IntegerToString(ms)+" ms";
   Print(txt);
   if(code==200)
     {
      CJson j;
      if(j.Parse(resp))
         Print("OpenAITest: reply: ",j.GetString("choices[0].message.content","(empty)"));
      else
         Print("OpenAITest: response not parseable: ",resp);
     }
   else
     {
      Print("OpenAITest: body: ",StringSubstr(resp,0,500));
     }
   FileWriteLog(txt);
  }

//+------------------------------------------------------------------+
void FileWriteLog(const string msg)
  {
   int h=FileOpen("OpenAITest.txt",FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(h==INVALID_HANDLE) return;
   FileWriteString(h,msg+"\r\n");
   FileClose(h);
  }
//+------------------------------------------------------------------+
