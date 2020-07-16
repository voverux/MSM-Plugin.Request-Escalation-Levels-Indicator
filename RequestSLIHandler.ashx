<%@ WebHandler Language="C#" Class="RequestSLIHandler" %>

using System;
using System.IO;
using System.Net;
using System.Web;
using System.Linq;
using System.Text.RegularExpressions;
using System.Collections.Generic;
using System.Xml.Serialization;
using Newtonsoft.Json;
using Newtonsoft.Json.Serialization;
using MarvalSoftware;
using MarvalSoftware.ServiceDesk.Facade;
using MarvalSoftware.Data.ServiceDesk;
using MarvalSoftware.DataTransferObjects;
using MarvalSoftware.ServiceDesk.ServiceSupport;
using MarvalSoftware.ServiceDesk.ServiceDelivery.ServiceLevelManagement;
using MarvalSoftware.UI.WebUI.ServiceDesk.RFP.Plugins;


/// <summary>
/// Request Dynamic Form Plugin Handler
/// </summary>
public class RequestSLIHandler : PluginHandler
{
    public override bool IsReusable { get { return false; } }

    /// <summary>
    /// Main Request Handler
    /// </summary>
    public override void HandleRequest(HttpContext context)
    {
        if (context.Request.HttpMethod == "GET")
        {
            int requestId = Int32.TryParse((context.Request.Params["RequestId"] ?? string.Empty), out requestId) ? requestId : 0;
            if (requestId == 0)
                context.Response.Write(JsonHelper.ToJSON(new EscalationLevels()));
            else 
                context.Response.Write(JsonHelper.ToJSON(getRequestEscalationLevels(requestId)));
                //context.Response.Write(JsonHelper.ToJSON(Test(requestId)));
        }
    }

    /// <summary>
    /// Get Request Escalation Levels (calculations are based on 'list_requests_[sla|ola|uc]Escalation' views)
    /// </summary>
    private EscalationLevels getRequestEscalationLevels(int requestId)
    {
        SystemSettingsInfo settings = new SystemSettingsBroker().GetSystemSettings();
		int lvlInactive = (int)settings.EscalationLevelIndicatorInactive;
		int lvlNew = (int)settings.EscalationLevelIndicatorNew;
		int lvlBreached = (int)settings.EscalationLevelIndicatorBreached;
        EscalationLevels el = new EscalationLevels(lvlInactive, lvlNew, lvlBreached);
        try
        {
            RequestBroker broker = new RequestBroker();
            RequestManagementFacade facade = new RequestManagementFacade();
            // Request rq = facade.BaseRequestBroker.Find(requestId, false);
            Request rq = broker.Find(requestId);
            if(rq != null)
            {
                bool isOnHold = false;
                bool responseBreached = false;
                bool fixBreached = false;

                el.Notes += "Request found. ";
                var calculator = new ServiceLevelsCalculator(rq, new RequestManagementFacade().ExecuteModifyAgreementRuleActionRulesSet);

				//-----------------
				//-- Get Breaches
				//-----------------
				Request.RequestBreachDates requestBreachDates = calculator.GetBreachDates();
				
				//-----------------
				//-- Recalculate Escalation Points
				//-----------------
                rq.AllCalculatedEscalationPoints = new RequestEscalationCollection
                {
                    calculator.CalculateSlaEscalationPoints(),
                    calculator.CalculateOlaEscalationPoints(),
                    calculator.CalculateUcEscalationPoints()
                };
                rq.CalculatedCurrentEscalationLevels = calculator.GetCurrentEscalationLevels();


				//=== SLA ===
                if(rq.ServiceLevelAgreement != null)
				{
                    el.Notes += "SLA exists. ";
                    el.Sla = lvlNew;
                    el.SlaState = "Response: New";
                    isOnHold = rq.IsOnHold && rq.ServiceLevelAgreement.ServiceLevels.DeductTimeInHoldState == HoldTimeBehaviours.DeductInRealTime;
					responseBreached = requestBreachDates.SlaBreaches.ActualResponseBreach > DateTime.MinValue;
					fixBreached = requestBreachDates.SlaBreaches.ActualFixBreach > DateTime.MinValue;
					
					if(rq.IsRespondedTo())
					{
                        el.SlaState = "Fix: New";
                        el.Notes += "SLA is responded. ";
						if(rq.IsFixed())
						{
							el.Sla = lvlInactive;
							el.SlaState = "Fix: Inactive (fixed)";
                            el.Notes += "Is fixed. ";
						}
						else
						{
                            el.Notes += "Is not fixed. ";
							if(fixBreached)
                            {
                                el.Sla = lvlBreached;
								el.SlaState = "Fix: Breached";
                                el.Notes += "SLA Fix is breached. ";
                            }
                            else
							{
                                el.Notes += "SLA Fix not breached. ";
								if(isOnHold)
								{
									el.Sla = lvlInactive;
									el.SlaState = "Fix: Inactive (on hold)";
                                    el.Notes += "SLA is on hold. ";
								}
								else
								{
                                    el.Notes += "SLA is not on hold. ";
									if (rq.CalculatedCurrentEscalationLevels.SlaFixEscalation != null && rq.CalculatedCurrentEscalationLevels.SlaFixEscalation.EscalationPoint != null)
                                    {
										el.Sla = rq.CalculatedCurrentEscalationLevels.SlaFixEscalation.EscalationPoint.IndicatorLevel;
										el.SlaState = "Fix: In progress";
                                        el.Notes += "SLA Fix EP level:" + el.Sla + " ";
                                    }
								}
							}
						}
					}
                    else
					{
                        el.Notes += "SLA is not responded. ";
						if(responseBreached)
                        {
                            el.Sla = lvlBreached;
							el.SlaState = "Response: Breached";
                            el.Notes += "SLA Response is breached. ";
                        }
                        else
						{
                            el.Notes += "SLA Response is not breached. ";
							if(isOnHold)
							{
								el.Sla = lvlInactive;
    							el.SlaState = "Response: Inactive (on hold)";
                                el.Notes += "SLA is on hold. ";
							}
							else
							{
                                el.Notes += "SLA is not on hold. ";
								if(rq.CalculatedCurrentEscalationLevels.SlaResponseEscalation != null && rq.CalculatedCurrentEscalationLevels.SlaResponseEscalation.EscalationPoint != null)
                                {
                                    el.Sla = rq.CalculatedCurrentEscalationLevels.SlaResponseEscalation.EscalationPoint.IndicatorLevel;
        							el.SlaState = "Response: In progress";
                                    el.Notes += "SLA Response EP level:" + el.Sla + " ";
                                }
							}
						}
					}
                }
                else
				{
					el.SlaState = "Inactive (not assigned)";
                    el.Notes += "SLA is not assigned. ";
                }

				//=== OLA ===
                if(rq.CurrentOperationalLevelAgreement != null)
				{
                    el.Notes += "OLA exists. ";
                    el.Ola = lvlNew;
                    el.OlaState = "Response: New";
                    isOnHold = rq.IsOnHold && rq.CurrentOperationalLevelAgreement.ServiceLevels.DeductTimeInHoldState == HoldTimeBehaviours.DeductInRealTime;
					responseBreached = requestBreachDates.OlaBreaches.ActualResponseBreach > DateTime.MinValue;
					fixBreached = requestBreachDates.OlaBreaches.ActualFixBreach > DateTime.MinValue;
                    bool isAssignmentResponded = rq.AssignmentResponseDate > DateTime.MinValue;
                    bool isAssignmentCompleted = rq.AssignmentRejectedDate > DateTime.MinValue || rq.AssignmentSuccessfullyCompletedDate > DateTime.MinValue || rq.AssignmentUnSuccessfullyCompletedDate > DateTime.MinValue;
					
					if(isAssignmentResponded)
					{
                        el.OlaState = "Fix: New";
                        el.Notes += "OLA Assignment is responded. ";
						if(isAssignmentCompleted)
						{
							el.Ola = lvlInactive;
							el.OlaState = "Fix: Inactive (completed)";
                            el.Notes += "OLA Assignment is completed. ";
						}
						else
						{
                            el.Notes += "OLA Assignment is not completed. ";
							if(fixBreached)
                            {
                                el.Ola = lvlBreached;
								el.OlaState = "Fix: Breached";
                                el.Notes += "OLA Fix is breached. ";
                            }
                            else
							{
                                el.Notes += "OLA Fix not breached. ";
								if(isOnHold)
								{
									el.Ola = lvlInactive;
									el.OlaState = "Fix: Inactive (on hold)";
                                    el.Notes += "OLA is on hold. ";
								}
								else
								{
                                    el.Notes += "OLA is not on hold. ";
									if (rq.CalculatedCurrentEscalationLevels.OlaFixEscalation != null && rq.CalculatedCurrentEscalationLevels.OlaFixEscalation.EscalationPoint != null)
                                    {
										el.Ola = rq.CalculatedCurrentEscalationLevels.OlaFixEscalation.EscalationPoint.IndicatorLevel;
										el.OlaState = "Fix: In progress";
                                        el.Notes += "OLA Fix EP level:" + el.Ola + " ";
                                    }
								}
							}
						}
					}
                    else
					{
                        el.Notes += "OLA Assignment is not responded. ";
						if(responseBreached)
                        {
                            el.Ola = lvlBreached;
							el.OlaState = "Response: Breached";
                            el.Notes += "OLA Assignment Response is breached. ";
                        }
                        else
						{
                            el.Notes += "OLA Assignment Response is not breached. ";
							if(isOnHold)
							{
								el.Ola = lvlInactive;
    							el.OlaState = "Response: Inactive (on hold)";
                                el.Notes += "OLA is on hold. ";
							}
							else
							{
                                el.Notes += "OLA is not on hold. ";
								if(rq.CalculatedCurrentEscalationLevels.OlaResponseEscalation != null && rq.CalculatedCurrentEscalationLevels.OlaResponseEscalation.EscalationPoint != null)
                                {
                                    el.Ola = rq.CalculatedCurrentEscalationLevels.OlaResponseEscalation.EscalationPoint.IndicatorLevel;
        							el.OlaState = "Response: In progress";
                                    el.Notes += "OLA Response EP level:" + el.Ola + " ";
                                }
							}
						}
					}
                }
                else
				{
					el.OlaState = "Inactive (not assigned)";
                    el.Notes += "OLA is not assigned. ";
                }


				//=== UC ===
                if(rq.CurrentUnderpinningContract != null)
				{
                    el.Notes += "UC exists. ";
                    el.Uc = lvlNew;
                    el.UcState = "Response: New";
                    isOnHold = rq.IsOnHold && rq.CurrentUnderpinningContract.ServiceLevels.DeductTimeInHoldState == HoldTimeBehaviours.DeductInRealTime;
					responseBreached = requestBreachDates.UcBreaches.ActualResponseBreach > DateTime.MinValue;
					fixBreached = requestBreachDates.UcBreaches.ActualFixBreach > DateTime.MinValue;
                    bool isAssignmentResponded = rq.AssignmentResponseDate > DateTime.MinValue;
                    bool isAssignmentCompleted = rq.AssignmentRejectedDate > DateTime.MinValue || rq.AssignmentSuccessfullyCompletedDate > DateTime.MinValue || rq.AssignmentUnSuccessfullyCompletedDate > DateTime.MinValue;
					
					if(isAssignmentResponded)
					{
                        el.UcState = "Fix: New";
                        el.Notes += "UC Assignment is responded. ";
						if(isAssignmentCompleted)
						{
							el.Uc = lvlInactive;
							el.OlaState = "Fix: Inactive (completed)";
                            el.Notes += "UC Assignment is completed. ";
						}
						else
						{
                            el.Notes += "UC Assignment is not completed. ";
							if(fixBreached)
                            {
                                el.Uc = lvlBreached;
								el.UcState = "Fix: Breached";
                                el.Notes += "UC Fix is breached. ";
                            }
                            else
							{
                                el.Notes += "UC Fix not breached. ";
								if(isOnHold)
								{
									el.Uc = lvlInactive;
									el.UcState = "Fix: Inactive (on hold)";
                                    el.Notes += "UC is on hold. ";
								}
								else
								{
                                    el.Notes += "UC is not on hold. ";
									if (rq.CalculatedCurrentEscalationLevels.UcFixEscalation != null && rq.CalculatedCurrentEscalationLevels.UcFixEscalation.EscalationPoint != null)
                                    {
										el.Uc = rq.CalculatedCurrentEscalationLevels.UcFixEscalation.EscalationPoint.IndicatorLevel;
										el.UcState = "Fix: In progress";
                                        el.Notes += "UC Fix EP level:" + el.Uc + " ";
                                    }
								}
							}
						}
					}
                    else
					{
                        el.Notes += "UC Assignment is not responded. ";
						if(responseBreached)
                        {
                            el.Uc = lvlBreached;
							el.UcState = "Response: Breached";
                            el.Notes += "UC Assignment Response is breached. ";
                        }
                        else
						{
                            el.Notes += "UC Assignment Response is not breached. ";
							if(isOnHold)
							{
								el.Uc = lvlInactive;
    							el.UcState = "Response: Inactive (on hold)";
                                el.Notes += "UC is on hold. ";
							}
							else
							{
                                el.Notes += "UC is not on hold. ";
								if(rq.CalculatedCurrentEscalationLevels.UcResponseEscalation != null && rq.CalculatedCurrentEscalationLevels.UcResponseEscalation.EscalationPoint != null)
                                {
                                    el.Uc = rq.CalculatedCurrentEscalationLevels.UcResponseEscalation.EscalationPoint.IndicatorLevel;
        							el.UcState = "Response: In progress";
                                    el.Notes += "UC Response EP level:" + el.Uc + " ";
                                }
							}
						}
					}
                }
                else
				{
					el.UcState = "Inactive (not assigned)";
                    el.Notes += "UC is not assigned. ";
                }
            }

        }
        catch (Exception ex) {
        }
        return el;
    }


    private class EscalationLevels
    {
        public int Sla { get; set; }
        public int Ola { get; set; }
        public int Uc { get; set; }
        public string SlaState { get; set; }
        public string OlaState { get; set; }
        public string UcState { get; set; }
        public int Inactive { get; set; }
        public int New { get; set; }
        public int Breached { get; set; }
        public string Notes { get; set; }

        public EscalationLevels()
        {
            this.Sla = 1;
            this.Ola = 1;
            this.Uc = 1;
            this.SlaState = string.Empty;
            this.OlaState = string.Empty;
            this.UcState = string.Empty;
            this.Inactive = 1;
            this.New = 3;
            this.Breached = 6;
            this.Notes = string.Empty;
        }
        public EscalationLevels(int InactiveLevel, int NewLevel, int BreachedLevel)
        {
            this.Sla = InactiveLevel;
            this.Ola = InactiveLevel;
            this.Uc = InactiveLevel;
            this.SlaState = string.Empty;
            this.OlaState = string.Empty;
            this.UcState = string.Empty;
            this.Inactive = InactiveLevel;
            this.New = NewLevel;
            this.Breached = BreachedLevel;
            this.Notes = string.Empty;
        }
    }
}

/// <summary>
/// JsonHelper Functions
/// </summary>
public static class JsonHelper
{
    public static string replaceLBs(string jsonString)
    {
        return Regex.Replace(jsonString, @"\""[^\""]*?[\n\r]+[^\""]*?\""", m => Regex.Replace(m.Value, @"[\n\r]", "\\n"));
    }
    public static string replaceWildcards(string jsonString)
    {
        return jsonString.Replace("\\n", "").Replace("\\\"", "\"");
    }
    public static string ToJSON(object obj)
    {
        return JsonConvert.SerializeObject(obj);
        //return JsonConvert.SerializeObject(obj, Newtonsoft.Json.Formatting.Indented, new JsonSerializerSettings { ReferenceLoopHandling = ReferenceLoopHandling.Serialize });
    }
    public static string SerializeJSONObject<T>(this T JsonObjectToSerialize)
    {
        JsonSerializerSettings jsonSettings = new JsonSerializerSettings()
        {
            TypeNameHandling = TypeNameHandling.Objects
        };
        //jsonSettings.TypeNameHandling = TypeNameHandling.Objects;
        //jsonSettings.MetadataPropertyHandling = MetadataPropertyHandling.Default;
        return JsonConvert.SerializeObject(JsonObjectToSerialize);
        //return JsonConvert.SerializeObject(JsonObjectToSerialize, Newtonsoft.Json.Formatting.Indented, jsonSettings);
    }
    public static T DeserializeJSONObject<T>(this string JsonStringToDeserialize)
    {

        JsonSerializerSettings jsonSettings = new JsonSerializerSettings()
        {
            TypeNameHandling = TypeNameHandling.Objects
        };
        //jsonSettings.TypeNameHandling = TypeNameHandling.Objects;
        //jsonSettings.MetadataPropertyHandling = MetadataPropertyHandling.Default;
        JsonSerializer serializer = new JsonSerializer();
        return JsonConvert.DeserializeObject<T>(JsonStringToDeserialize);
        //return JsonConvert.DeserializeObject<T>(JsonStringToDeserialize, jsonSettings);
    }
}

