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
        EscalationLevels el = new EscalationLevels(settings.EscalationLevelIndicatorInactive);
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
                    el.Sla = (int)settings.EscalationLevelIndicatorNew;
                    isOnHold = rq.IsOnHold && rq.ServiceLevelAgreement.ServiceLevels.DeductTimeInHoldState == HoldTimeBehaviours.DeductInRealTime;
					
					responseBreached = requestBreachDates.SlaBreaches.ActualResponseBreach > DateTime.MinValue;
					fixBreached = requestBreachDates.SlaBreaches.ActualFixBreach > DateTime.MinValue;
					
					if(rq.IsRespondedTo())
					{
                        el.Notes += "SLA is responded. ";
						if(rq.IsFixed())
						{
                            el.Notes += "Is fixed. ";
							el.Sla = (int)settings.EscalationLevelIndicatorInactive;
						}
						else
						{
                            el.Notes += "Is not fixed. ";
							if(fixBreached)
                            {
                                el.Notes += "SLA Fix is breached. ";
                                el.Sla = (int)settings.EscalationLevelIndicatorBreached;
                            }
                            else
							{
                                el.Notes += "SLA Fix not breached. ";
								if(isOnHold)
								{
                                    el.Notes += "SLA is on hold. ";
									el.Sla = (int)settings.EscalationLevelIndicatorInactive;
								}
								else
								{
                                    el.Notes += "SLA is not on hold. ";
									if (rq.CalculatedCurrentEscalationLevels.SlaFixEscalation != null && rq.CalculatedCurrentEscalationLevels.SlaFixEscalation.EscalationPoint != null)
                                    {
										el.Sla = rq.CalculatedCurrentEscalationLevels.SlaFixEscalation.EscalationPoint.IndicatorLevel;
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
                            el.Notes += "SLA Response is breached. ";
                            el.Sla = (int)settings.EscalationLevelIndicatorBreached;
                        }
                        else
						{
                            el.Notes += "SLA Response is not breached. ";
							if(isOnHold)
							{
                                el.Notes += "SLA is on hold. ";
								el.Sla = (int)settings.EscalationLevelIndicatorInactive;
							}
							else
							{
                                el.Notes += "SLA is not on hold. ";
								if(rq.CalculatedCurrentEscalationLevels.SlaResponseEscalation != null && rq.CalculatedCurrentEscalationLevels.SlaResponseEscalation.EscalationPoint != null)
                                {
                                    el.Sla = rq.CalculatedCurrentEscalationLevels.SlaResponseEscalation.EscalationPoint.IndicatorLevel;
                                    el.Notes += "SLA Response EP level:" + el.Sla + " ";
                                }
							}
						}
					}
                }
                else
				{
                    el.Notes += "SLA is not assigned. ";
                }

				//=== OLA ===
                if(rq.CurrentOperationalLevelAgreement != null)
				{
                    el.Notes += "OLA exists. ";
                    el.Ola = (int)settings.EscalationLevelIndicatorNew;
                    isOnHold = rq.IsOnHold && rq.CurrentOperationalLevelAgreement.ServiceLevels.DeductTimeInHoldState == HoldTimeBehaviours.DeductInRealTime;
					responseBreached = requestBreachDates.OlaBreaches.ActualResponseBreach > DateTime.MinValue;
					fixBreached = requestBreachDates.OlaBreaches.ActualFixBreach > DateTime.MinValue;
                    bool isAssignmentResponded = rq.AssignmentResponseDate > DateTime.MinValue;
                    bool isAssignmentCompleted = rq.AssignmentRejectedDate > DateTime.MinValue || rq.AssignmentSuccessfullyCompletedDate > DateTime.MinValue || rq.AssignmentUnSuccessfullyCompletedDate > DateTime.MinValue;
					
					if(isAssignmentResponded)
					{
                        el.Notes += "OLA Assignment is responded. ";
						if(isAssignmentCompleted)
						{
                            el.Notes += "OLA Assignment is completed. ";
							el.Ola = (int)settings.EscalationLevelIndicatorInactive;
						}
						else
						{
                            el.Notes += "OLA Assignment is not completed. ";
							if(fixBreached)
                            {
                                el.Notes += "OLA Fix is breached. ";
                                el.Ola = (int)settings.EscalationLevelIndicatorBreached;
                            }
                            else
							{
                                el.Notes += "OLA Fix not breached. ";
								if(isOnHold)
								{
                                    el.Notes += "OLA is on hold. ";
									el.Ola = (int)settings.EscalationLevelIndicatorInactive;
								}
								else
								{
                                    el.Notes += "OLA is not on hold. ";
									if (rq.CalculatedCurrentEscalationLevels.OlaFixEscalation != null && rq.CalculatedCurrentEscalationLevels.OlaFixEscalation.EscalationPoint != null)
                                    {
										el.Ola = rq.CalculatedCurrentEscalationLevels.OlaFixEscalation.EscalationPoint.IndicatorLevel;
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
                            el.Notes += "OLA Assignment Response is breached. ";
                            el.Ola = (int)settings.EscalationLevelIndicatorBreached;
                        }
                        else
						{
                            el.Notes += "OLA Assignment Response is not breached. ";
							if(isOnHold)
							{
                                el.Notes += "OLA is on hold. ";
								el.Ola = (int)settings.EscalationLevelIndicatorInactive;
							}
							else
							{
                                el.Notes += "OLA is not on hold. ";
								if(rq.CalculatedCurrentEscalationLevels.OlaResponseEscalation != null && rq.CalculatedCurrentEscalationLevels.OlaResponseEscalation.EscalationPoint != null)
                                {
                                    el.Ola = rq.CalculatedCurrentEscalationLevels.OlaResponseEscalation.EscalationPoint.IndicatorLevel;
                                    el.Notes += "OLA Response EP level:" + el.Ola + " ";
                                }
							}
						}
					}
                }
                else
				{
                    el.Notes += "OLA is not assigned. ";
                }


				//=== UC ===
                if(rq.CurrentUnderpinningContract != null)
				{
                    el.Notes += "UC exists. ";
                    el.Uc = (int)settings.EscalationLevelIndicatorNew;
                    isOnHold = rq.IsOnHold && rq.CurrentUnderpinningContract.ServiceLevels.DeductTimeInHoldState == HoldTimeBehaviours.DeductInRealTime;
					responseBreached = requestBreachDates.UcBreaches.ActualResponseBreach > DateTime.MinValue;
					fixBreached = requestBreachDates.UcBreaches.ActualFixBreach > DateTime.MinValue;
                    bool isAssignmentResponded = rq.AssignmentResponseDate > DateTime.MinValue;
                    bool isAssignmentCompleted = rq.AssignmentRejectedDate > DateTime.MinValue || rq.AssignmentSuccessfullyCompletedDate > DateTime.MinValue || rq.AssignmentUnSuccessfullyCompletedDate > DateTime.MinValue;
					
					if(isAssignmentResponded)
					{
                        el.Notes += "UC Assignment is responded. ";
						if(isAssignmentCompleted)
						{
                            el.Notes += "UC Assignment is completed. ";
							el.Uc = (int)settings.EscalationLevelIndicatorInactive;
						}
						else
						{
                            el.Notes += "UC Assignment is not completed. ";
							if(fixBreached)
                            {
                                el.Notes += "UC Fix is breached. ";
                                el.Uc = (int)settings.EscalationLevelIndicatorBreached;
                            }
                            else
							{
                                el.Notes += "UC Fix not breached. ";
								if(isOnHold)
								{
                                    el.Notes += "UC is on hold. ";
									el.Uc = (int)settings.EscalationLevelIndicatorInactive;
								}
								else
								{
                                    el.Notes += "UC is not on hold. ";
									if (rq.CalculatedCurrentEscalationLevels.UcFixEscalation != null && rq.CalculatedCurrentEscalationLevels.UcFixEscalation.EscalationPoint != null)
                                    {
										el.Uc = rq.CalculatedCurrentEscalationLevels.UcFixEscalation.EscalationPoint.IndicatorLevel;
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
                            el.Notes += "UC Assignment Response is breached. ";
                            el.Uc = (int)settings.EscalationLevelIndicatorBreached;
                        }
                        else
						{
                            el.Notes += "UC Assignment Response is not breached. ";
							if(isOnHold)
							{
                                el.Notes += "UC is on hold. ";
								el.Uc = (int)settings.EscalationLevelIndicatorInactive;
							}
							else
							{
                                el.Notes += "UC is not on hold. ";
								if(rq.CalculatedCurrentEscalationLevels.UcResponseEscalation != null && rq.CalculatedCurrentEscalationLevels.UcResponseEscalation.EscalationPoint != null)
                                {
                                    el.Uc = rq.CalculatedCurrentEscalationLevels.UcResponseEscalation.EscalationPoint.IndicatorLevel;
                                    el.Notes += "UC Response EP level:" + el.Uc + " ";
                                }
							}
						}
					}
                }
                else
				{
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
        public string Notes { get; set; }

        public EscalationLevels()
        {
            this.Sla = 1;
            this.Ola = 1;
            this.Uc = 1;
            this.Notes = string.Empty;
        }
        public EscalationLevels(int InactiveLevel)
        {
            this.Sla = InactiveLevel;
            this.Ola = InactiveLevel;
            this.Uc = InactiveLevel;
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
