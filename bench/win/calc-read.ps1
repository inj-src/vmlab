# Print Calculator's display text via UI Automation (must run in the desktop session).
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$root = [Windows.Automation.AutomationElement]::RootElement
$cond = New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::AutomationIdProperty, 'CalculatorResults')
$el = $root.FindFirst([Windows.Automation.TreeScope]::Descendants, $cond)
if ($el) { $el.Current.Name } else { 'NO-CALC' }
