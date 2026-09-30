//+------------------------------------------------------------------+
//|                                            include/OpenAIClient.mqh |
//|  OpenAI Chat Completions client with tool (function) calling.    |
//|                                                                  |
//|  NOTE: MQL5 WebRequest is BLOCKING, so this client is fully      |
//|  synchronous: SendRequest() performs the HTTP call and parses    |
//|  the reply in one shot. The EA drives the tool-calling loop:     |
//|                                                                  |
//|    SendRequest()  -> if PendingCount()>0: execute tools, then    |
//|                       FeedToolResults(results) and loop back to  |
//|                       SendRequest() until HasFinalAnswer().      |
//+------------------------------------------------------------------+
#ifndef MQL5_OPENAI_OPENAI_CLIENT_MQH
#define MQL5_OPENAI_OPENAI_CLIENT_MQH

#include "HttpClient.mqh"
#include "Json.mqh"

class COpenAIClient
  {
private:
   string   m_apiKey;
   string   m_baseUrl;      // e.g. https://api.openai.com/v1
   string   m_model;
   double   m_temperature;
   int      m_maxTokens;
   string   m_toolsJson;    // JSON array of tool schemas (functions)
   int      m_maxToolRounds;

   CHttpClient m_http;
   string   m_lastError;

   //--- context trimming for small-context models (e.g. JEV 32K)
   int      m_maxHistoryChars;   // 0 = no trimming

   //--- request state
   string   m_messages;     // serialized messages array (grows as we go)
   string   m_rawResp;      // latest raw response body
   int      m_round;
   bool     m_finalAnswer;
   string   m_answer;
   string   m_pendingCalls; // raw JSON array of pending tool calls
   string   m_callIds[];    // parallel arrays of the pending calls
   string   m_callNames[];
   string   m_callArgs[];

   //--- build message array JSON from full text
   static string MsgRole(const string role,const string content)
     {
      return "{\"role\":"+CJson::Quote(role)+
             ",\"content\":"+CJson::Quote(content)+"}";
     }
   static string AssistantWithCalls(const string content,const string callsJson)
     {
      string c=(content=="")?"null":CJson::Quote(content);
      return "{\"role\":\"assistant\",\"content\":"+c+
             ",\"tool_calls\":"+callsJson+"}";
     }

   bool ParsePendingCalls(const string body);
   void ClearPending(void);
   static string TrimMessages(const string msgs,const int maxChars);

public:
   COpenAIClient(void);
   void   Setup(const string apiKey,const string baseUrl,const string model,
                const double temperature,const int maxTokens,
                const string toolsJson,const int maxToolRounds,
                const int maxHistoryChars=0);
   void   NewConversation(const string systemPrompt,const string firstUserMsg);
   bool   SendRequest(void);                       // blocking; parses reply
   void   FeedToolResults(const string resultsJson); // append tool results
                                                    // (resultsJson: comma-joined
                                                    //  tool messages, NO brackets)

   //--- state getters
   string   LastError(void) const       { return m_lastError; }
   string   RawResponse(void) const     { return m_rawResp; }   // last raw body
   bool     HasFinalAnswer(void) const  { return m_finalAnswer; }
   string   Answer(void) const          { return m_answer; }
   int      PendingCount(void) const;
   string   PendingCallId(const int i) const;
   string   PendingCallName(const int i) const;
   string   PendingCallArgs(const int i) const;
   string   PendingCallsJson(void) const { return m_pendingCalls; }
   void     DisableTools(void)          { m_toolsJson="[]"; } // force an answer
  };

//+------------------------------------------------------------------+
COpenAIClient::COpenAIClient(void)
  {
   m_apiKey="";
   m_baseUrl="https://api.openai.com/v1";
   m_model="gpt-4o-mini";
   m_temperature=0.2;
   m_maxTokens=2000;
   m_toolsJson="[]";
   m_maxToolRounds=5;
   m_maxHistoryChars=0;
   m_lastError="";
   m_messages="";
   m_rawResp="";
   m_round=0;
   m_finalAnswer=false;
   m_answer="";
   m_pendingCalls="[]";
  }

void COpenAIClient::Setup(const string apiKey,const string baseUrl,const string model,
                          const double temperature,const int maxTokens,
                          const string toolsJson,const int maxToolRounds,
                          const int maxHistoryChars)
  {
   m_apiKey=apiKey;
   if(StringLen(baseUrl)>0)
     {
      m_baseUrl=baseUrl;
      // strip trailing slash
      if(StringGetCharacter(m_baseUrl,StringLen(m_baseUrl)-1)=='/')
         m_baseUrl=StringSubstr(m_baseUrl,0,StringLen(m_baseUrl)-1);
     }
   if(StringLen(model)>0) m_model=model;
   m_temperature=temperature;
   m_maxTokens=maxTokens;
   m_toolsJson=toolsJson;
   m_maxToolRounds=(maxToolRounds>0)?maxToolRounds:5;
   m_maxHistoryChars=(maxHistoryChars>0)?maxHistoryChars:0;
  }

void COpenAIClient::NewConversation(const string systemPrompt,const string firstUserMsg)
  {
   m_messages="[";
   m_messages+=MsgRole("system",systemPrompt);
   if(firstUserMsg!="")
     {
      m_messages+=",";
      m_messages+=MsgRole("user",firstUserMsg);
     }
   m_messages+="]";
   m_round=0;
   m_finalAnswer=false;
   m_answer="";
   m_pendingCalls="[]";
   ClearPending();
   m_lastError="";
  }

void COpenAIClient::ClearPending(void)
  {
   ArrayResize(m_callIds,0);
   ArrayResize(m_callNames,0);
   ArrayResize(m_callArgs,0);
   m_pendingCalls="[]";
  }

int COpenAIClient::PendingCount(void) const
  {
   return ArraySize(m_callIds);
  }

string COpenAIClient::PendingCallId(const int i) const
  {
   if(i<0 || i>=ArraySize(m_callIds)) return "";
   return m_callIds[i];
  }

string COpenAIClient::PendingCallName(const int i) const
  {
   if(i<0 || i>=ArraySize(m_callNames)) return "";
   return m_callNames[i];
  }

string COpenAIClient::PendingCallArgs(const int i) const
  {
   if(i<0 || i>=ArraySize(m_callArgs)) return "";
   return m_callArgs[i];
  }

//--- Parse a response body into the pending tool calls state.
//    Returns true when the assistant asked for tool calls.
bool COpenAIClient::ParsePendingCalls(const string body)
  {
   ClearPending();
   CJson j;
   if(!j.Parse(body))
     {
      m_lastError="parse error: "+j.Error();
      return false;
     }
   // possible error payload from OpenAI
   if(j.Has("error"))
     {
      m_lastError="API error: "+j.GetString("error.message","(no message)")+
                  " (type="+j.GetString("error.type","")+")";
      return false;
     }
   int nChoices=j.Count("choices");
   if(nChoices<=0)
     {
      m_lastError="API returned no choices";
      return false;
     }
   string msg="choices[0].message";
   int nCalls=j.Count(msg+".tool_calls");
   if(nCalls<=0)
     {
      // final answer
      m_answer=j.GetString(msg+".content","");
      m_finalAnswer=true;
      return true;
     }
   // collect tool calls
   for(int i=0;i<nCalls;i++)
     {
      string base=StringFormat("%s.tool_calls[%d]",msg,i);
      string id=j.GetString(base+".id","");
      string name=j.GetString(base+".function.name","");
      string args=j.GetString(base+".function.arguments","");
      if(name=="") continue;
      int k=ArraySize(m_callIds);
      ArrayResize(m_callIds,k+1);
      ArrayResize(m_callNames,k+1);
      ArrayResize(m_callArgs,k+1);
      m_callIds[k]=id;
      m_callNames[k]=name;
      m_callArgs[k]=args;
     }
   if(ArraySize(m_callIds)==0)
     {
      m_lastError="assistant tool_calls present but no usable function";
      return false;
     }
   // store the raw calls json so the EA can pass it back verbatim
   m_pendingCalls=j.GetRaw(msg+".tool_calls");
   return true;
  }

//--- Simple message-array trimmer: keeps the first (system) message
//    and the last portion of the array so the whole thing fits
//    maxChars. Splits on ",{" boundaries to stay valid JSON.
string COpenAIClient::TrimMessages(const string msgs,const int maxChars)
  {
   if(StringLen(msgs)<=maxChars) return msgs;
   // find the end of the first message (first ",{" after index 1)
   int firstEnd=StringFind(msgs,",{",1);
   if(firstEnd<0) return StringSubstr(msgs,0,maxChars);   // single message
   string head=StringSubstr(msgs,0,firstEnd+1);           // system msg + ","
   string rest=StringSubstr(msgs,firstEnd+1);
   // trim rest from the front until it fits (drop oldest tool/assistant msgs)
   int budget=maxChars-StringLen(head)-1;
   if(budget<0) budget=0;
   string tail=rest;
   while(StringLen(tail)>budget)
     {
      int cut=StringFind(tail,",{",1);
      if(cut<0)
        {
         tail=StringSubstr(tail,0,budget);
         break;
        }
      tail=StringSubstr(tail,cut+1);
     }
   return head+tail;
  }

//--- Start a request (BLOCKING HTTP). Parses the reply and fills the
//    pending-tool-calls arrays when the assistant asks for tools.
bool COpenAIClient::SendRequest(void)
  {
   if(m_apiKey=="")
     {
      m_lastError="API key not configured";
      return false;
     }
   // context trimming for small-context models: keep system message
   // plus the most recent messages within the character budget.
   string msgs=m_messages;
   if(m_maxHistoryChars>0 && StringLen(msgs)>m_maxHistoryChars)
      msgs=TrimMessages(msgs,m_maxHistoryChars);
   // build body
   string body="{";
   body+="\"model\":"+CJson::Quote(m_model);
   body+=",\"messages\":"+msgs;
   body+=",\"temperature\":"+DoubleToString(m_temperature,2);
   body+=",\"max_tokens\":"+IntegerToString(m_maxTokens);
   if(m_toolsJson!="" && m_toolsJson!="[]")
     {
      body+=",\"tools\":"+m_toolsJson;
      body+=",\"tool_choice\":\"auto\"";
     }
   body+="}";

   // fail fast on a malformed body (e.g. a hand-written tool schema with
   // a missing brace) instead of letting the API return a cryptic 400
   string jerr="";
   if(!CJson::IsBalanced(body,jerr))
     {
      m_lastError="request body is not valid JSON: "+jerr;
      return false;
     }

   // "Connection: close" avoids reusing a keep-alive socket the proxy may
   // already have dropped while we were idle between polls; such a stale
   // reuse surfaces as a bogus status code with an empty body.
   string headers="Authorization: Bearer "+m_apiKey+
                   "\r\nContent-Type: application/json"+
                   "\r\nConnection: close";

   string url=m_baseUrl+"/chat/completions";
   string respHeaders="";
   m_rawResp="";
   ResetLastError();
   int code=m_http.PostJson(url,headers,body,60000,m_rawResp,respHeaders);
   // one transparent retry on an empty-bodied failure (stale socket / hiccup)
   if(code!=200 && StringLen(m_rawResp)==0)
     {
      Sleep(1200);
      m_rawResp="";
      ResetLastError();
      code=m_http.PostJson(url,headers,body,60000,m_rawResp,respHeaders);
     }
   if(code<0)
     {
      m_lastError=m_http.LastError();
      return false;
     }
   if(code!=200)
     {
      // include the request size: gateways often reject oversized contexts
      m_lastError=StringFormat("HTTP %d (request %d bytes): %s",
                               code,StringLen(body),m_rawResp);
      return false;
     }
   m_round++;
   return ParsePendingCalls(m_rawResp);
  }

//--- Append tool results and prepare the conversation for one more
//    round. resultsJson is a FULL JSON array "[...]" of tool-role
//    messages (built by the EA in ProcessToolCalls); we unwrap the
//    outer brackets and splice the items into the message array.
void COpenAIClient::FeedToolResults(const string resultsJson)
  {
   string items=resultsJson;
   int L=StringLen(items);
   if(L>=2 && StringGetCharacter(items,0)=='[')
      items=StringSubstr(items,1,L-2);   // strip [ ]
   string asst=AssistantWithCalls("",m_pendingCalls);
   int cut=StringLen(m_messages)-1;
   // ... ] -> ...,assistant-with-calls,<tool items> ]
   m_messages=StringSubstr(m_messages,0,cut)+","+asst+
              ((items!="")?","+items:"")+"]";
   m_pendingCalls="[]";
   ClearPending();
   m_finalAnswer=false;
  }

#endif // MQL5_OPENAI_OPENAI_CLIENT_MQH
