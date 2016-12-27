/*

Custom Ouplan Post-Processor based on Stroom's OpenBuildsGRBL https://github.com/Strooom/GRBL-Post-Processor/wiki that in tur is based on the PP for http://openbuilds.com
This post-Processor was developed for a Ouplan 2515 with automatic tool change should work in other Ouplan Milling Machines

!THIS POST PROCESSOR IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND!
!USE IT WISELY AND AT YOUR OWN RISK!



22/AUG/2016 - V1 : Kick Off
23/AUG/2016 - V2 : Added Machining Time to Operations overview at file header
24/AUG/2016 - V3 : Added extra user properties - further cleanup of unused variables
07/SEP/2016 - V4 : Added support for INCHES. Added a safe retract at beginning of first section
11/OCT/2016 - V5
27/DEC/2016 - V6 : Adaptation to Ouplan's G-Code Standard By:X3msnake
					- Add fastmoves override
					- Add hasAutoTools (not working)
					- Add optional line numbers
					- Add trim white space

> TABLE OF CONTENTS AT THE END OF THE FILE <					
*/

description = "OuplanXYZ - W/ARCS";
vendor = "Ouplan";
vendorUrl = "";
model = "2515";
description = "OuplanXYZ - W/ARCS";
legal = "Copyright (C) 2012-2016 by Autodesk, Inc.";
certificationLevel = 2;

extension = "nc";							// file extension of the gcode file
setCodePage("ascii");						// character set of the gcode file
//setEOL(CRLF);								// end-of-line type : use CRLF for windows

capabilities = CAPABILITY_MILLING;			// intended for a CNC, so Milling
tolerance = spatial(0.05, MM);				// (0.05mm) Ouplan's 2515 advertised accuracy 
minimumChordLength = spatial(0.01, MM);
minimumCircularRadius = spatial(0.01, MM);
maximumCircularRadius = spatial(1000, MM);
minimumCircularSweep = toRad(0.01);
maximumCircularSweep = toRad(180);
allowHelicalMoves = true;
allowedCircularPlanes = undefined;

var GRBLunits = MM;						// GRBL controller set to mm (Metric). Allows for a consistency check between GRBL settings and CAM file output
										// var GRBLunits = IN;

// user-defined properties : defaults are set, but they can be changed from a dialog box in Fusion when doing a post.
properties =
	{
	spindleOnOffDelay: 0,				// time (in seconds) the spindle needs to get up to speed or stop
	spindleTwoDirections : false,		// true : spindle can rotate clockwise and counterclockwise, will send M3 and M4. false : spindle can only go clockwise, will only send M3
	hasCoolant : true,					// true : machine uses the coolant output, M8 M9 will be sent. false : coolant output not connected, so no M8 M9 will be sent
	hasAutoTools : true,				// 
	hasSpeedDial : false,				// true : the spindle is of type Makite RT0700, Dewalt 611 with a Dial to set speeds 1-6. false : other spindle
	machineHomeZ : 230,					// absolute machine coordinates where the machine will move to at the end of the job - first retracting Z, then moving home X Y
	machineHomeX : 20,
	machineHomeY : 20,
	useFastMoves : true,				// false: G0 fast moves are replaced by G1 motion moves, usefull when testing to avoid crashing tools 
	trimWhiteSpaces: false,				// true: compacts file by removing white spaces between commands
	useLineNumbers: false,				// false: removes line numbering from the posted code
	sequenceNumberStart: 10, 			// first sequence number
    sequenceNumberIncrement: 10 		// increment for sequence numbers	
	};

// creation of all kinds of G-code formats - controls the amount of decimals used in the generated G-Code
var nFormat = createFormat({prefix:"N", decimals:0}); // Used for line Number
var sequenceNumber = properties.sequenceNumberStart;  // Set line counter
var gFormat = createFormat({prefix:"G", decimals:0}); // Used for motion and coordinate manipulation
var mFormat = createFormat({prefix:"M", decimals:0}); // Used for machine actions and activations
var tFormat = createFormat({prefix:"T", decimals:0}); // Used for tools

var xyzFormat = createFormat({decimals:(unit == MM ? 3 : 4), forceDecimal:true});
var feedFormat = createFormat({decimals:0});
var rpmFormat = createFormat({decimals:0});
var secFormat = createFormat({decimals:1, forceDecimal:true});
var taperFormat = createFormat({decimals:1, scale:DEG});

var xOutput = createVariable({prefix:"X"}, xyzFormat);
var yOutput = createVariable({prefix:"Y"}, xyzFormat);
var zOutput = createVariable({prefix:"Z"}, xyzFormat);
var feedOutput = createVariable({prefix:"F"}, feedFormat);
var sOutput = createVariable({prefix:"S", force:true}, rpmFormat);

var iOutput = createReferenceVariable({prefix:"I"}, xyzFormat);
var jOutput = createReferenceVariable({prefix:"J"}, xyzFormat);
var kOutput = createReferenceVariable({prefix:"K"}, xyzFormat);

var gMotionModal = createModal({}, gFormat); 											// modal group 1 // G0-G3, ...
var gPlaneModal = createModal({onchange:function () {gMotionModal.reset();}}, gFormat); // modal group 2 // G17-19
var gAbsIncModal = createModal({}, gFormat); 											// modal group 3 // G90-91
var gFeedModeModal = createModal({}, gFormat); 											// modal group 5 // G93-94
var gUnitModal = createModal({}, gFormat); 												// modal group 6 // G20-21

function toTitleCase(str)
	{
	// function to reformat a string to 'title case'
    return str.replace(/\w\S*/g, function(txt){return txt.charAt(0).toUpperCase() + txt.substr(1).toLowerCase();});
	}
	
function rpm2dial(rpm)
	{
	// translates an RPM for the spindle into a dial value, eg for the Makita RT0700 and Dewalt 611 routers
	// additionaly, check that spindle rpm is between minimun and maximum of what our spindle can do

	// array which maps spindle speeds to router dial settings,
	// according to Makita RT0700 Manual : 1=10000, 2=12000, 3=17000, 4=22000, 5=27000, 6=30000
	var speeds = [0, 10000, 12000, 17000, 22000, 27000, 30000];

	if (rpm < speeds[1])
		{
		alert("Warning", rpm + " rpm is below minimum spindle RPM of " + speeds[1] + " rpm");
		return 1;
		}

	if (rpm > speeds[speeds.length - 1])
		{
		alert("Warning", rpm + " rpm is above maximum spindle RPM of " + speeds[speeds.length - 1] + " rpm");
		return (speeds.length - 1);
		}

	var i;
	for (i=1; i < (speeds.length-1); i++)
		{
		if ((rpm >= speeds[i]) && (rpm <= speeds[i+1]))
			{
			return ((rpm - speeds[i]) / (speeds[i+1] - speeds[i])) + i;
			}
		}

	alert("Error", "Error in calculating router speed dial..");
	error("Fatal Error calculating router speed dial");
	return 0;
	}

function writeBlock() {
  if (properties.useLineNumbers) {
    writeWords2(nFormat.format(sequenceNumber % 100000), arguments);
    sequenceNumber += properties.sequenceNumberIncrement;
  } else {
    writeWords(arguments);
  }
}

function writeComment(text)
	{
	// Remove special characters which could confuse GRBL : $, !, ~, ?, (, )
	// In order to make it simple, I replace everything which is not A-Z, 0-9, space, : , .
	// Finally put everything between () as this is the way GRBL & UGCS expect comments
	writeln("(" + String(text).replace(/[^a-zA-Z\d :=,.]+/g, " ") + ")");
	}

	
// 1. START POST-PROCESSING (header)
function onOpen()
	{
		if (properties.trimWhiteSpaces) { 
			setWordSeparator("");
		}
  
  
// Number of checks capturing fatal errors
// 1.1 is CAD file in same units as our GRBL configuration ?
	if (unit != GRBLunits)
		{
		if (GRBLunits == MM)
			{
			alert("Error", "GRBL configured to mm - CAD file sends Inches! - Change units in CAD/CAM software to mm");
			error("Fatal Error : units mismatch between CADfile and GRBL setting");
			}
		else
			{
			alert("Error", "GRBL configured to inches - CAD file sends mm! - Change units in CAD/CAM software to inches");
			error("Fatal Error : units mismatch between CADfile and GRBL setting");
			}
		}

		
// 1.2 is RadiusCompensation not set incorrectly ?
	onRadiusCompensation();
		
		
// 1.3 here you set all the properties of your machine, so they can be used later on
	var myMachine = getMachineConfiguration();
	myMachine.setWidth(2700);
	myMachine.setDepth(1580);
	myMachine.setHeight(100);
	myMachine.setMaximumSpindlePower(4500);
	myMachine.setMaximumSpindleSpeed(24000);
	myMachine.setMilling(true);
	myMachine.setTurning(false);
	myMachine.setToolChanger(true);
	myMachine.setNumberOfTools(5);
	myMachine.setNumberOfWorkOffsets(6);
	myMachine.setVendor("Ouplan");
	myMachine.setModel("2515");
	myMachine.setControl("InoControl");


// 1.4 Write Program Settings in comment form
	writeln("%");

	var productName = getProduct(); 						// var from the CAM software
	writeComment("Made in : " + productName);
	writeComment("G-Code optimized for " + myMachine.getVendor() + " " + myMachine.getModel() + " with " + myMachine.getControl() + " controller");

	writeln("");
	
	if (programName) 										// if set get var from the CAM software
		{
		writeComment("Program Name : " + programName);
		}
	if (programComment)										// if set get var from the CAM software
		{
		writeComment("Program Comments : " + programComment);
		}
	
	
// 1.5 Write Tool blocks actions in comment form
	var numberOfSections = getNumberOfSections();
	writeComment(numberOfSections + " Operation" + ((numberOfSections == 1)?"":"s") + " :");

	for (var i = 0; i < numberOfSections; ++i)
		{
        var section = getSection(i);
        var tool = section.getTool();
		var rpm = section.getMaximumSpindleSpeed();

		if (section.hasParameter("operation-comment"))
			{
			writeComment((i+1) + " : " + section.getParameter("operation-comment"));
			}
		else
			{
			writeComment(i+1);
			}

		writeComment("  Work Coordinate System : G" + (section.workOffset + 53));
		writeComment("  Tool : " + toTitleCase(getToolTypeName(tool.type)) + " " + tool.numberOfFlutes + " Flutes, Diam = " + xyzFormat.format(tool.diameter) + "mm, Len = " + tool.fluteLength + "mm");
		if (properties.hasSpeedDial)
			{
			writeComment("  Spindle : RPM = " + rpm + ", set router dial to " + rpm2dial(rpm));
			}
		else
			{
			writeComment("  Spindle : RPM = " + rpm);
			}
		var machineTimeInSeconds = section.getCycleTime();
		var machineTimeHours = Math.floor(machineTimeInSeconds / 3600);
		machineTimeInSeconds  = machineTimeInSeconds % 3600;
		var machineTimeMinutes = Math.floor(machineTimeInSeconds / 60);
		var machineTimeSeconds = Math.floor(machineTimeInSeconds % 60);
		var machineTimeText = "  Machining time : ";
		if (machineTimeHours > 0)
			{
			machineTimeText = machineTimeText + machineTimeHours + " hours " + machineTimeMinutes + " min ";
			}
		else if (machineTimeMinutes > 0)
			{
			machineTimeText = machineTimeText + machineTimeMinutes + " min ";
			}
		machineTimeText = machineTimeText + machineTimeSeconds + " sec";
		writeComment(machineTimeText);
		}
	writeln("");
		
// 1.6 Set machine to a known state 
	// (M20/21)  Set inches / mm
	// (G94) 	 Set Feed mm/min
	// (G90) 	 Set Absolute Coordinates
	// (G17) 	 Set Arc Plane XY
	// (G40/G49) Disable tool radius and height offsets
	// (G80) 	 Disable canned cycles
	
	switch (unit)
		{
		case IN:
			writeBlock(gUnitModal.format(20));
			break;
		case MM:
			writeBlock(gUnitModal.format(21));
			break;
		}
		
	writeBlock(gFeedModeModal.format(94));
	writeBlock(gAbsIncModal.format(90));
	writeBlock(gPlaneModal.format(17));
	writeBlock(gFeedModeModal.format(40), gFeedModeModal.format(49));
	writeBlock(gFeedModeModal.format(80));

	writeln("");
	}

// 2. POST COMMENTS
function onComment(message)
	{
	writeComment(message);
	}
	
// 3. FORCE USE ONLY 3 AXIS	
function forceXYZ()
	{
	xOutput.reset();
	yOutput.reset();
	zOutput.reset();
	}
	
// 3.2 FORCE USE ONLY 3 AXIS	
function forceAny()
	{
	forceXYZ();
	feedOutput.reset();
	}
	
// 4. POST SECTIONS
function onSection()
	{
	var nmbrOfSections = getNumberOfSections();		// how many operations are there in total
	var sectionId = getCurrentSectionId();			// what is the number of this operation (starts from 0)
	var section = getSection(sectionId);			// what is the section-object for this operation

	// Insert a small comment section to identify the related G-Code in a large multi-operations file
	var comment = "Operation " + (sectionId + 1) + " of " + nmbrOfSections;
	if (hasParameter("operation-comment"))
		{
		comment = comment + " : " + getParameter("operation-comment");
		}
	writeComment(comment);
	writeln("");

	
// 4.1 Safe Move to Absolute Machine Z Coordinates Set on the CAM Properties panel
	// To be safe (after jogging to whatever position), move the spindle up to a safe home position before going to the inital position
	// At end of a section, spindle is retrated to clearance height, so it is only needed on the first section
	// it is done with G53 - machine coordinates, so I put it in front of anything else
	if(isFirstSection())
		{
		writeBlock(gAbsIncModal.format(90), gFormat.format(53), gFormat.format(properties.useFastMoves ? 0 : 1), "Z" + xyzFormat.format(properties.machineHomeZ));	// Retract spindle to Machine Z Home
		}

// 4.2 Validate and post CAM Set coordinate system
	// Write the WCS, ie. G54 or higher.. default to WCS1 / G54 if no or invalid WCS in order to prevent using Machine Coordinates G53
	if ((section.workOffset < 1) || (section.workOffset > 6))
		{
		alert("Warning", "Invalid Work Coordinate System. Select WCS 1..6 in CAM software. Selecting default WCS1/G54");
		section.workOffset = 1;	// If no WCS is set (or out of range), then default to WCS1 / G54
		}
	writeBlock(gFormat.format(53 + section.workOffset));

	
	
// 4.3 Load/Change Tool
	// (T#)	Select Operation Block Tool
	// (M6)	Automatic Load Tool
		var tool = section.getTool();
		writeBlock(tFormat.format(tool.number), mFormat.format(6));

// 4.4 Start Spindle
	// (S#) 	Spindle RPM Speed
	// (M3/M4) 	Start Spindle CW/CCW 

	if (tool.clockwise)
		{
		writeBlock(sOutput.format(tool.spindleRPM), mFormat.format(3));
		}
	else if (properties.spindleTwoDirections)
		{
		writeBlock(sOutput.format(tool.spindleRPM), mFormat.format(4));
		}
	else
		{
		alert("Error", "Counter-clockwise Spindle Operation found, but your spindle does not support this");
		error("Fatal Error in Operation " + (sectionId + 1) + ": Counter-clockwise Spindle Operation found, but your spindle does not support this");
		return;
		}
		
// 4.5 Wait for tool ready	
	// Wait some time for spindle to speed up - only on first section, as spindle is not powered down in-between sections
	if(isFirstSection())
		{
		onDwell(properties.spindleOnOffDelay);
		}

// 4.6 Start Coolant (M7/M8) Mist/Flood (M9) Disable Coolant 
	// If the machine has coolant, write M8 or M9
	if (properties.hasCoolant)
		{
		if (tool.coolant)
			{
			writeBlock(mFormat.format(8));		
			}
		else
			{
			writeBlock(mFormat.format(9));		
			}
		}
	
// 4.7 forceXYZ
	forceXYZ();

    var remaining = currentSection.workPlane;
    if (!isSameDirection(remaining.forward, new Vector(0, 0, 1)))
		{
		alert("Error", "Tool-Rotation detected - GRBL ony supports 3 Axis");
		error("Fatal Error in Operation " + (sectionId + 1) + ": Tool-Rotation detected but GRBL ony supports 3 Axis");
		}
    setRotation(remaining);

// 4.8 forceAny
	forceAny();

// 4.9 Rapid Move to section Initial Position
	// First XY, then Z
	var initialPosition = getFramePosition(currentSection.getInitialPosition());
	writeBlock(gFormat.format(properties.useFastMoves ? 0 : 1), xOutput.format(initialPosition.x), yOutput.format(initialPosition.y));
	writeBlock(gAbsIncModal.format(90), gFormat.format(properties.useFastMoves ? 0 : 1), zOutput.format(initialPosition.z));
	
	}

// 5 OTHER FUNCTIONS

// 5.1 OnDwell
function onDwell(seconds)
	{
	if (properties.spindleOnOffDelay > 0 )
		{
		writeBlock(gFormat.format(4), "P" + secFormat.format(seconds));
		}
	}
	
// 5.2 OnSpindleSpeed
function onSpindleSpeed(spindleSpeed)
	{
	writeBlock(sOutput.format(spindleSpeed));
	}

// 5.3 onRadiusCompensation
function onRadiusCompensation()
	{
	var radComp = getRadiusCompensation();
	var sectionId = getCurrentSectionId();	
	if (radComp != RADIUS_COMPENSATION_OFF)
		{
		alert("Error", "RadiusCompensation is not supported in GRBL - Change RadiusCompensation in CAD/CAM software to Off/Center/Computer");
		error("Fatal Error in Operation " + (sectionId + 1) + ": RadiusCompensation is found in CAD file but is not supported in GRBL");
		return;
		}
	}

// 5.4 onRapid
function onRapid(_x, _y, _z)
	{
	var x = xOutput.format(_x);
	var y = yOutput.format(_y);
	var z = zOutput.format(_z);
	if (x || y || z)
		{
		writeBlock(gFormat.format(properties.useFastMoves ? 0 : 1), x, y, z);
		feedOutput.reset();
		}
	}

// 5.5 onLinear
function onLinear(_x, _y, _z, feed)
	{
	var x = xOutput.format(_x);
	var y = yOutput.format(_y);
	var z = zOutput.format(_z);
	var f = feedOutput.format(feed);

	if (x || y || z)
		{
		writeBlock(gMotionModal.format(1), x, y, z, f);
		}
	else if (f)
		{
		if (getNextRecord().isMotion())
			{
			feedOutput.reset(); // force feed on next line
			}
		else
			{
			writeBlock(gMotionModal.format(1), f);
			}
		}
	}
	
// 5.6 onRapid5D
function onRapid5D(_x, _y, _z, _a, _b, _c)
	{
	alert("Error", "Tool-Rotation detected - GRBL ony supports 3 Axis");
	error("Tool-Rotation detected but GRBL ony supports 3 Axis");
	}
	
// 5.7 onLinear5D
function onLinear5D(_x, _y, _z, _a, _b, _c, feed)
	{
	alert("Error", "Tool-Rotation detected - GRBL ony supports 3 Axis");
	error("Tool-Rotation detected but GRBL ony supports 3 Axis");
	}
	
// 5.8 onCircular
function onCircular(clockwise, cx, cy, cz, x, y, z, feed)
	{
	var start = getCurrentPosition();

	if (isFullCircle())
		{
		if (isHelical())
			{
			linearize(tolerance);
			return;
			}

		switch (getCircularPlane())
			{
			case PLANE_XY:
				writeBlock(gPlaneModal.format(17), gMotionModal.format(clockwise ? 2 : 3), xOutput.format(x), iOutput.format(cx - start.x, 0), jOutput.format(cy - start.y, 0), feedOutput.format(feed));
				break;
			case PLANE_ZX:
				writeBlock(gPlaneModal.format(18), gMotionModal.format(clockwise ? 2 : 3), zOutput.format(z), iOutput.format(cx - start.x, 0), kOutput.format(cz - start.z, 0), feedOutput.format(feed));
				break;
			case PLANE_YZ:
				writeBlock(gPlaneModal.format(19), gMotionModal.format(clockwise ? 2 : 3), yOutput.format(y), jOutput.format(cy - start.y, 0), kOutput.format(cz - start.z, 0), feedOutput.format(feed));
				break;
			default:
				linearize(tolerance);
			}
		}
	else
		{
		switch (getCircularPlane())
			{
			case PLANE_XY:
				writeBlock(gPlaneModal.format(17), gMotionModal.format(clockwise ? 2 : 3), xOutput.format(x), yOutput.format(y), zOutput.format(z), iOutput.format(cx - start.x, 0), jOutput.format(cy - start.y, 0), feedOutput.format(feed));
				break;
			case PLANE_ZX:
				writeBlock(gPlaneModal.format(18), gMotionModal.format(clockwise ? 2 : 3), xOutput.format(x), yOutput.format(y), zOutput.format(z), iOutput.format(cx - start.x, 0), kOutput.format(cz - start.z, 0), feedOutput.format(feed));
				break;
			case PLANE_YZ:
				writeBlock(gPlaneModal.format(19), gMotionModal.format(clockwise ? 2 : 3), xOutput.format(x), yOutput.format(y), zOutput.format(z), jOutput.format(cy - start.y, 0), kOutput.format(cz - start.z, 0), feedOutput.format(feed));
				break;
			default:
				linearize(tolerance);
			}
		}
	}
	
// 5.8 onSectionEnd
function onSectionEnd()
	{
	// writeBlock(gPlaneModal.format(17));
	forceAny();
	writeln("");
	}
	
// 6 END POST-PROCESSING (footer)
function onClose()
	{
	if (properties.hasCoolant)
		{
		writeBlock(mFormat.format(9));																				// Stop Coolant
		}
	writeBlock(gAbsIncModal.format(90), gFormat.format(53), gFormat.format(properties.useFastMoves ? 0 : 1), "Z" + xyzFormat.format(properties.machineHomeZ));	// Retract spindle to Machine Z Home
	writeBlock(mFormat.format(5));																					// Stop Spindle
	onDwell(properties.spindleOnOffDelay);																			// Wait for spindle to stop
	writeBlock(gAbsIncModal.format(90), gFormat.format(53), gFormat.format(properties.useFastMoves ? 0 : 1), "X" + xyzFormat.format(properties.machineHomeX), "Y" + xyzFormat.format(properties.machineHomeY));	// Return to home position
	writeBlock(mFormat.format(30));																					// Program End
	writeln("%");																									// Punch-Tape End
	}
	

// TOC
// 1. START POST-PROCESSING (header)
// 1.1 is CAD file in same units as our GRBL configuration ?	
// 1.2 is RadiusCompensation not set incorrectly ?	
// 1.3 here you set all the properties of your machine, so they can be used later on
// 1.4 Write Program Settings in comment form
// 1.5 Write Tool blocks actions in comment form
// 1.6 Set machine to a known state
// 2. POST COMMENTS
// 3. FORCE USE ONLY 3 AXIS	
// 3.1 FORCE USE ONLY 3 AXIS	
// 4. POST SECTIONS
	// 4.1 Safe Move to Absolute Machine Z Coordinates Set on the CAM Properties panel
	// 4.2 Validate and post CAM Set coordinate system
	// 4.3 Load/Change Tool
	// 4.4 Start Spindle
	// 4.5 Wait for tool ready	
	// 4.6 Start Coolant (M7/M8) Mist/Flood (M9) Disable Coolant 
	// 4.7 forceXYZ
	// 4.8 forceAny
	// 4.9 Rapid Move to section Initial Position
// 5 OTHER FUNCTIONS
	// 5.1 OnDwell
	// 5.2 OnSpindleSpeed
	// 5.3 onRadiusCompensation
	// 5.4 onRapid
	// 5.5 onLinear
	// 5.6 onRapid5D
	// 5.7 onLinear5D	
	// 5.8 onCircular
	// 5.8 onSectionEnd
// 6 END POST-PROCESSING (footer)

