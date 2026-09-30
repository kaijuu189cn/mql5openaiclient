//+------------------------------------------------------------------+
//|                                             include/JevClient.mqh |
//|  Client for the TypeSafe Jev decision model via OpenRouter's     |
//|  Decisions API (POST /api/alpha/decisions).                      |
//|                                                                  |
//|  Jev is NOT a chat model: it takes a `state` object + typed      |
//|  `questions` and returns structured answers with probabilities   |
//|  (choice / noul / score). See:                                   |
//|    https://openrouter.ai/docs/guides/community/jev               |
//|                                                                  |
//|  Question types:                                                 |
//|    choice : {"type":"choice","instructions":"...","criteria":{   |
//|              "opt1":"desc","opt2":"desc",...}}                   |
//|    noul   : {"type":"noul","instructions":"...","criteria":{     |
//|              "true":"...","false":"..."}}                        |
//|    score  : {"type":"score","instructions":"...","criteria":[    |
//|              "level0","level1",...]}                             |
//|  Answers:                                                        |
//|    choice: {type, choice, probabilities{...}, confidence}        |
//|    noul  : {type, noul(0..1)}                                    |
//|    score : {type, score(0..len-1), legend, probabilities,        |
//|             confidence}                                          |
//+------------------------------------------------------------------+
#ifndef MQL5_OPENAI_JEV_CLIENT_MQH
#define MQL5_OPENAI_JEV_CLIENT_MQH

#include "HttpClient.mqh"
#include "Json.mqh"

class CJevClient
  {
private:
   string   m_apiKey;
   string   m_baseUrl;      // https://openrouter.ai
   string   m_model;
   CHttpClient m_http;
   string   m_lastError;
   string   m_rawResp;
   string   m_answers;      // raw JSON of the answers object
   bool     m_ok;

public:
   CJevClient(void);

   void   Setup(const string apiKey,const string baseUrl,const string model);

   //--- submits the decision request (blocking)
   bool   Decide(const string state,const string questionsJson);

   //--- answer getters (call after Decide()==true)
   bool     HasAnswer(const string qid) const;
   string   AnswerType(const string qid) const;          // choice|noul|score
   string   ChoiceValue(const string qid) const;         // choice answer
   double   ChoiceProbability(const string qid,const string opt) const;
   double   ChoiceConfidence(const string qid) const;
   double   NoulValue(const string qid) const;           // 0..1
   double   ScoreValue(const string qid) const;          // 0..N
   double   ScoreConfidence(const string qid) const;
   string   RawAnswers(void) const     { return m_answers; }
   string   LastError(void) const      { return m_lastError; }
  };

//+------------------------------------------------------------------+
CJevClient::CJevClient(void)
  {
   m_apiKey="";
   m_baseUrl="https://openrouter.ai";
   m_model="typesafe/jev-1.13";
   m_lastError="";
   m_rawResp="";
   m_answers="";
   m_ok=false;
  }

void CJevClient::Setup(const string apiKey,const string baseUrl,const string model)
  {
   m_apiKey=apiKey;
   if(StringLen(baseUrl)>0)
     {
      m_baseUrl=baseUrl;
      int L=StringLen(m_baseUrl);
      if(L>0 && StringGetCharacter(m_baseUrl,L-1)=='/')
         m_baseUrl=StringSubstr(m_baseUrl,0,L-1);
     }
   if(StringLen(model)>0) m_model=model;
  }

bool CJevClient::Decide(const string state,const string questionsJson)
  {
   m_lastError="";
   m_ok=false;
   m_answers="";
   if(m_apiKey=="")
     {
      m_lastError="API key not configured";
      return false;
     }
   string body="{";
   body+="\"model\":"+CJson::Quote(m_model);
   body+=",\"state\":"+state;
   body+=",\"questions\":"+questionsJson;
   body+="}";

   string headers="Authorization: Bearer "+m_apiKey+
                  "\r\nContent-Type: application/json";
   string url=m_baseUrl+"/api/alpha/decisions";
   string respHeaders="";
   m_rawResp="";
   ResetLastError();
   int code=m_http.PostJson(url,headers,body,30000,m_rawResp,respHeaders);
   if(code<0)
     {
      m_lastError=m_http.LastError();
      return false;
     }
   if(code!=200)
     {
      m_lastError=StringFormat("HTTP %d: %s",code,m_rawResp);
      return false;
     }
   CJson j;
   if(!j.Parse(m_rawResp))
     {
      m_lastError="parse error: "+j.Error();
      return false;
     }
   if(j.Has("error"))
     {
      m_lastError="API error: "+j.GetString("error.message","(no message)");
      return false;
     }
   m_answers=j.GetRaw("answers");
   if(m_answers=="null" || m_answers=="")
     {
      m_lastError="no answers in response";
      return false;
     }
   m_ok=true;
   return true;
  }

bool CJevClient::HasAnswer(const string qid) const
  {
   CJson j;
   if(!j.Parse(m_answers)) return false;
   return j.Has(qid);
  }

string CJevClient::AnswerType(const string qid) const
  {
   CJson j;
   if(!j.Parse(m_answers)) return "";
   return j.GetString(qid+".type","");
  }

string CJevClient::ChoiceValue(const string qid) const
  {
   CJson j;
   if(!j.Parse(m_answers)) return "";
   return j.GetString(qid+".choice","");
  }

double CJevClient::ChoiceProbability(const string qid,const string opt) const
  {
   CJson j;
   if(!j.Parse(m_answers)) return 0;
   return j.GetDouble(qid+".probabilities."+opt,0);
  }

double CJevClient::ChoiceConfidence(const string qid) const
  {
   CJson j;
   if(!j.Parse(m_answers)) return 0;
   return j.GetDouble(qid+".confidence",0);
  }

double CJevClient::NoulValue(const string qid) const
  {
   CJson j;
   if(!j.Parse(m_answers)) return 0;
   return j.GetDouble(qid+".noul",0);
  }

double CJevClient::ScoreValue(const string qid) const
  {
   CJson j;
   if(!j.Parse(m_answers)) return 0;
   return j.GetDouble(qid+".score",0);
  }

double CJevClient::ScoreConfidence(const string qid) const
  {
   CJson j;
   if(!j.Parse(m_answers)) return 0;
   return j.GetDouble(qid+".confidence",0);
  }

#endif // MQL5_OPENAI_JEV_CLIENT_MQH
