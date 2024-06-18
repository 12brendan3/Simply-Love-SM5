local GetSimfileString = function(steps)
	-- steps:GetFilename() returns the filename of the sm or ssc file, including path, as it is stored in SM's cache
	local filename = steps:GetFilename()
	if not filename or filename == "" then return end

	-- get the file extension like "sm" or "SM" or "ssc" or "SSC" or "sSc" or etc.
	-- convert to lowercase
	local filetype = filename:match("[^.]+$"):lower()
	-- if file doesn't match "ssc" or "sm", it was (hopefully) something else (.dwi, .bms, etc.)
	-- that isn't supported by SL-ChartParser
	if not (filetype=="ssc" or filetype=="sm") then return end

	-- create a generic RageFile that we'll use to read the contents
	-- of the desired .ssc or .sm file
	local f = RageFileUtil.CreateRageFile()
	local contents

	-- the second argument here (the 1) signals
	-- that we are opening the file in read-only mode
	if f:Open(filename, 1) then
		contents = f:Read()
	end

	-- destroy the generic RageFile now that we have the contents
	f:destroy()
	return contents, filetype
end

-- Reduce the chart to it's smallest unique representable form.
local MinimizeChart = function(chartString)
	local function MinimizeMeasure(measure)
		local minimal = false
		-- We can potentially minimize the chart to get the most compressed
		-- form of the actual chart data.
		-- NOTE(teejusb): This can be more compressed than the data actually
		-- generated by StepMania. This is okay because the charts would still
		-- be considered equivalent.
		-- E.g. 0000                      0000
		--      0000  -- minimized to -->
		--      0000
		--      0000
		--      StepMania will always generate the former since quarter notes are
		--      the smallest quantization.
		while not minimal and #measure % 2 == 0 do
			-- If every other line is all 0s, we can minimize the measure.
			local allZeroes = true
			for i=2, #measure, 2 do
				-- Check if the row is NOT all zeroes (thus we can't minimize).
				if measure[i] ~= string.rep('0', measure[i]:len()) then
					allZeroes = false
					break
				end
			end

			if allZeroes then
				-- To remove every other element while keeping the
				-- indices valid, we iterate from [2, len(t)/2 + 1].
				-- See the example below (where len(t) == 6).

				-- index: 1 2 3 4 5 6  -> remove index 2
				-- value: a b a b a b

				-- index: 1 2 3 4 5    -> remove index 3
				-- value: a a b a b

				-- index: 1 2 3 4      -> remove index 4
				-- value: a a a b

				-- index: 1 2 3
				-- value: a a a
				for i=2, #measure/2+1 do
					table.remove(measure, i)
				end
			else
				minimal = true
			end
		end
	end

	local finalChartData = {}
	local curMeasure = {}
	for line in chartString:gmatch('[^\n]+') do
		-- If we hit a comma, that denotes the end of a measure.
		-- Try to minimize it, and then add it to the final chart data with
		-- the delimiter.
		-- Note: The ending semi-colon has been stripped out.
		if line == ',' then
			MinimizeMeasure(curMeasure)

			for row in ivalues(curMeasure) do
				table.insert(finalChartData, row)
			end
			table.insert(finalChartData, ',')
			-- Just keep removing the first element to clear the table.
			-- This way we don't need to wait for the GC to cleanup the unused values.
			for i=1, #curMeasure do
				table.remove(curMeasure, 1)
			end
		else
			table.insert(curMeasure, line)
		end
	end

	-- Add the final measure.
	if #curMeasure > 0 then
		MinimizeMeasure(curMeasure)

		for row in ivalues(curMeasure) do
			table.insert(finalChartData, row)
		end
	end

	return table.concat(finalChartData, '\n')
end

local NormalizeFloatDigits = function(param)
	local function NormalizeDecimal(decimal)
		-- Remove any control characters from the string to prevent conversion failures.
		decimal = decimal:gsub("%c", "")
		local rounded = tonumber(decimal)

		-- Round to 3 decimal places
		local mult = 10^3
		rounded = (rounded * mult + 0.5 - (rounded * mult + 0.5) % 1) / mult
		return string.format("%.3f", rounded)
	end

	local paramParts = {}
	for beat_bpm in param:gmatch('[^,]+') do
		local beat, bpm = beat_bpm:match('(.+)=(.+)')
		table.insert(paramParts, NormalizeDecimal(beat) .. '=' .. NormalizeDecimal(bpm))
	end
	return table.concat(paramParts, ',')
end

-- ----------------------------------------------------------------
-- Takes a string and generates a case insensitive regex pattern.
-- e.g. "BPMS" returns "[Bb][Pp][Mm][Ss]""
local MixedCaseRegex = function(str)
	local t = {}
	for c in str:gmatch(".") do
		t[#t+1] = "[" .. c:upper() .. c:lower() .. "]"
	end
	return table.concat(t, "")
end

-- ----------------------------------------------------------------
-- ORIGINAL SOURCE: https://github.com/JonathanKnepp/SM5StreamParser

-- GetSimfileChartString() accepts four arguments:
--    SimfileString - the contents of the ssc or sm file as a string
--    StepsType     - a string like "dance-single" or "pump-double"
--    Difficulty    - a string like "Beginner" or "Challenge" or "Edit"
--    Filetype      - either "sm" or "ssc"
--
-- GetSimfileChartString() returns two value:
--    NoteDataString, a substring from SimfileString that contains the just the requested (minimized) note data
--    BPMs, a substring from SimfileString that contains the BPM string for this specific chart

local GetSimfileChartString = function(SimfileString, StepsType, Difficulty, StepsDescription, Filetype)
	local NoteDataString = nil
	local BPMs = nil

	-- Support lowercased variants.
	StepsType = StepsType:lower()
	Difficulty = Difficulty:lower()

	local BPMS = MixedCaseRegex("BPMS")
	local NOTEDATA = MixedCaseRegex("NOTEDATA")
	local NOTES = MixedCaseRegex("NOTES")
	local STEPSTYPE = MixedCaseRegex("STEPSTYPE")
	local DIFFICULTY = MixedCaseRegex("DIFFICULTY")
	local DESCRIPTION = MixedCaseRegex("DESCRIPTION")

	-- ----------------------------------------------------------------
	-- StepMania uses each steps' "Description" attribute to uniquely
	-- identify Edit charts. (This is important, because there can be more
	-- than one Edit chart.)
	--
	-- SSC files use a dedicated #DESCRIPTION for this purpose
	-- SM files use the 3rd spot in the #NOTES field for this purpose
	-- ----------------------------------------------------------------

	if Filetype == "ssc" then
		local topLevelBpm = NormalizeFloatDigits(SimfileString:match("#"..BPMS..":(.-);"):gsub("%s+", ""))
		-- SSC File
		-- Loop through each chart in the SSC file
		for noteData in SimfileString:gmatch("#"..NOTEDATA..".-#"..NOTES.."2?:[^;]*") do
			-- Normalize all the line endings to '\n'
			local normalizedNoteData = noteData:gsub('\r\n?', '\n')

			-- WHY? Why does StepMania allow the same fields to be defined multiple times
			-- in a single NOTEDATA stanza.
			-- We'll just use the first non-empty one.
			-- TODO(teejsub): Double check the expected behavior even though it is
			-- currently sufficient for all ranked charts on GrooveStats.
			local stepsType = ''
			for st in normalizedNoteData:gmatch("#"..STEPSTYPE..":(.-);") do
				if stepsType == '' and st ~= '' then
					stepsType = st
					break
				end
			end
			stepsType = stepsType:gsub("%s+", ""):lower()

			local difficulty = ''
			for diff in normalizedNoteData:gmatch("#"..DIFFICULTY..":(.-);") do
				if difficulty == '' and diff ~= '' then
					difficulty = diff
					break
				end
			end
			difficulty = difficulty:gsub("%s+", ""):lower()

			local description = ''
			for desc in normalizedNoteData:gmatch("#"..DESCRIPTION..":(.-);") do
				if description == '' and desc ~= '' then
					description = desc
					break
				end
			end

			-- Find the chart that matches our difficulty and game type.
			if (stepsType == StepsType and difficulty == Difficulty) then
				-- Ensure that we've located the correct edit stepchart within the SSC file.
				-- There can be multiple Edit stepcharts but each is guaranteed to have a unique #DESCRIPTION tag
				if (difficulty ~= "edit" or description == StepsDescription) then
					-- Get chart specific BPMS (if any).
					local splitBpm = normalizedNoteData:match("#"..BPMS..":(.-);") or ''
					splitBpm = splitBpm:gsub("%s+", "")

					if #splitBpm == 0 then
						BPMs = topLevelBpm
					else
						BPMs = NormalizeFloatDigits(splitBpm)
					end
					-- Get the chart data, remove comments, and then get rid of all non-'\n' whitespace.
					NoteDataString = normalizedNoteData:match("#"..NOTES.."2?:[\n]*([^;]*)\n?$"):gsub("//[^\n]*", ""):gsub('[\r\t\f\v ]+', '')
					NoteDataString = MinimizeChart(NoteDataString)
					break
				end
			end
		end
	elseif Filetype == "sm" then
		-- SM FILE
		BPMs = NormalizeFloatDigits(SimfileString:match("#"..BPMS..":(.-);"):gsub("%s+", ""))
		-- Loop through each chart in the SM file
		for noteData in SimfileString:gmatch("#"..NOTES.."2?[^;]*") do
			-- Normalize all the line endings to '\n'
			local normalizedNoteData = noteData:gsub('\r\n?', '\n')
			-- Split the entire chart string into pieces on ":"
			local parts = {}
			for match in (normalizedNoteData..":"):gmatch("([^:]*):") do
				parts[#parts+1] = part
			end

			-- The pieces table should contain at least 7 numerically indexed items
			-- 2, 4, (maybe 3) and 7 are the indices we care about for finding the correct chart
			-- Index 2 will contain the steps_type (like "dance-single")
			-- Index 4 will contain the difficulty (like "challenge")
			-- Index 3 will contain the description for Edit charts
			if #parts >= 7 then
				local stepsType = parts[2]:gsub("[^%w-]", ""):lower()
				-- Normalize the parsed difficulty (e.g. expert/oni should map to challenge).
				local difficulty = parts[4]:gsub("[^%w]", "")
				difficulty = ToEnumShortString(OldStyleStringToDifficulty(difficulty)):lower()
				local description = parts[3]:gsub("^%s*(.-)", "")
				-- Find the chart that matches our difficulty and game type.
				if (stepsType == StepsType and difficulty == Difficulty) then
					-- Ensure that we've located the correct edit stepchart within the SSC file.
					-- There can be multiple Edit stepcharts but each is guaranteed to have a unique #DESCRIPTION tag
					if (difficulty ~= "edit" or description == StepsDescription) then
						NoteDataString = parts[7]:gsub("//[^\n]*", ""):gsub('[\r\t\f\v ]+', '')
						NoteDataString = MinimizeChart(NoteDataString)
						break
					end
				end
			end
		end
	end

	return NoteDataString, BPMs
end

-- ----------------------------------------------------------------
-- Figure out which measures are considered a stream of notes
-- The chartString is expected to be minimized.
local GetMeasureInfo = function(Steps, chartString)
	-- Stream Measures Variables
	-- Which measures are considered a stream?
	local notesPerMeasure = {}
	local equallySpacedPerMeasure = {}
	local measureCount = 1
	local notesInMeasure = 0  -- The tap notes found in this measure
	local rowsInMeasure = 0   -- The total rows in this measure (can be just 1 if measure is empty).

	-- NPS and Density Graph Variables
	local NPSperMeasure = {}
	local NPSForThisMeasure, peakNPS = 0, 0
	local timingData = Steps:GetTimingData()

	-- Column Cues variables.
	local columnCueAllData = {} 
	local columnTimes = {}

	-- Loop through each line in our string of measures, trimming potential leading whitespace (thanks, TLOES/Mirage Garden)
	for line in chartString:gmatch("[^%s*\r\n]+") do
		-- If we hit a comma or a semi-colon, then we've hit the end of our measure
		if(line:match("^[,;]%s*")) then
			-- Does the number of notes in this measure meet our threshold to be considered a stream?
			table.insert(notesPerMeasure, notesInMeasure)
			table.insert(equallySpacedPerMeasure, notesInMeasure == rowsInMeasure)

			-- Column Cue calculation
			for noteData in ivalues(columnCueAllData) do
				local beat = 4 * ((measureCount-1) + (noteData.rowNum-1)/rowsInMeasure)
				columnTimes[#columnTimes + 1] = {
					columns=noteData.columns,
					time=timingData:GetElapsedTimeFromBeat(beat)
				}
			end

			-- NPS Calculation
			durationOfMeasureInSeconds = timingData:GetElapsedTimeFromBeat(measureCount * 4) - timingData:GetElapsedTimeFromBeat((measureCount-1)*4)

			-- FIXME: We subtract the time at the current measure from the time at the next measure to determine
			-- the duration of this measure in seconds, and use that to calculate notes per second.
			--
			-- Measures *normally* occur over some positive quantity of seconds.  Measures that use warps,
			-- negative BPMs, and negative stops are normally reported by the SM5 engine as having a duration
			-- of 0 seconds, and when that happens, we safely assume that there were 0 notes in that measure.
			--
			-- This doesn't always hold true.  Measures 48 and 49 of "Mudkyp Korea/Can't Nobody" use a properly
			-- timed negative stop, but the engine reports them as having very small but positive durations
			-- which erroneously inflates the notes per second calculation.
			--
			-- As a hold over for this case, we check that the duration is <= 0.12 (instead of 0), so this only
			-- breaks for cases where charts are of 2,000 BPM (which are likely rarer than those with warps).
			if durationOfMeasureInSeconds <= 0.12 then
				NPSForThisMeasure = 0
			else
				NPSForThisMeasure = notesInMeasure/durationOfMeasureInSeconds
			end

			NPSperMeasure[measureCount] = NPSForThisMeasure

			-- determine whether this measure contained the PeakNPS
			if NPSForThisMeasure > peakNPS then
				peakNPS = NPSForThisMeasure
			end

			-- Reset iterative variables
			notesInMeasure = 0
			rowsInMeasure = 0
			measureCount = measureCount + 1
			columnCueAllData = {}
		else
			rowsInMeasure = rowsInMeasure + 1
			-- Is this a note? (Tap, Hold Head, Roll Head)
			if(line:match("[124]")) then
				notesInMeasure = notesInMeasure + 1
			end

			-- For column cues, also keep track of mines
			if line:match("[124M]") then
				-- Find all the columns where the tap notes/mines occur.
				-- This is used for the ColumnCues.
				local columns = {}
				local i = 0
				while true do
					i = line:find("[124M]", i+1)
					if i == nil then break end
					columns[#columns+1] = {
						colNum=i,
						isMine=line:sub(i, i) == "M"
					}
				end
				columnCueAllData[#columnCueAllData+1] = {
					rowNum=rowsInMeasure,
					columns=columns
				}
			end
		end
	end

	local columnCues = {}
	local prevTime = 0
	for columnTime in ivalues(columnTimes) do
		local duration = columnTime.time - prevTime
		if duration >= SL.Global.ColumnCueMinTime or prevTime == 0 then
			columnCues[#columnCues + 1] = {
				columns=columnTime.columns,
				startTime=prevTime,
				duration=duration
			}
		end
		prevTime = columnTime.time
	end

	return notesPerMeasure, peakNPS, NPSperMeasure, columnCues, equallySpacedPerMeasure
end
-- ----------------------------------------------------------------

local GetTechniques = function(chartString)
	local RegexStep = "[124]"
	local RegexAny = "." -- "[%dM]" -- performance, i think

	local RegexL = "^" .. RegexStep .. RegexAny .. RegexAny .. RegexAny
	local RegexD = "^" .. RegexAny .. RegexStep .. RegexAny .. RegexAny
	local RegexU = "^" .. RegexAny .. RegexAny .. RegexStep .. RegexAny
	local RegexR = "^" .. RegexAny .. RegexAny .. RegexAny .. RegexStep

	-- Output counters
	local NumCrossovers = 0
	local NumFootswitches = 0
	local NumSideswitches = 0
	local NumJacks = 0
	local NumBrackets = 0

	-- Transient algorithm state
	local LastFoot = false -- false = left, true = right
	local WasLastStreamFlipped = false
	local LastStep -- Option<LDUR>
	local LastRepeatedFoot -- Option<LDUR>
	-- TODO: Microoptimize(?) by counting `NumLRCrossed` explicitly here,
	-- and maybe even eg `NumConsecutiveFlipped`. test on long trancemania songs
	local StepsLR = {}
	local AnyStepsSinceLastCommitStream = false

	-- Used for Brackets
	-- Tracks the last arrow(s) (can be plural in the case of brackets themselves)
	-- that each of the L and R feet was last on, respectively; However,
	-- note that this can be flipped while recording a (unflipped?) stream...
	local LastArrowL = "X"
	local LastArrowR = "X"
	-- ...so these track the true state of what happened (which become known only
	-- after deciding whether to flip, hence are updated every CommitStream)
	-- NB: These are "X" not "" b/c we use them in `match()`, and "" shouldn't match
	local TrueLastArrowL = "X"
	local TrueLastArrowR = "X"
	local TrueLastFoot = nil
	local JustBracketed = false

	-- TODO(bracket) - Figure out what corner cases this is needed for...?
	-- local justBracketed = false -- used for tiebreaks

	function CommitStream(tieBreakFoot)
		local ns = #StepsLR
		local nx = 0
		for step in ivalues(StepsLR) do
			-- Count crossed-over steps given initial footing
			if not step then nx = nx + 1 end
		end

		local needFlip = false
		if nx * 2 > ns then
			-- Easy case - more than half the L/R steps in this stream were crossed over,
			-- so we guessed the initial footing wrong and need to flip the stream.
			needFlip = true
		elseif nx * 2 == ns then
			-- Exactly half crossed over. Note that flipping the stream will introduce
			-- a jack (i.e. break the alternating-feet assumption) on the first note,
			-- whereas leaving it as is will footswitch that note. Break the tie by
			-- looking at history to see if the chart is already more jacky or switchy.
			-- (OTOH, the reverse applies if the previous stream was also flipped.)
			if tieBreakFoot then
				-- But first, as a higher priority tiebreaker -- if this stream is followed
				-- by a bracketable jump, choose whichever flipness lets us bracket it.
				if JustBracketed then
					-- (However, don't get too overzealous -- if also preceded by a
					-- bracket jump, that forces the footing, so we can't bracket both)
					needFlip = false
				elseif LastFoot then
					needFlip = (tieBreakFoot == "R")
				else
					needFlip = (tieBreakFoot == "L")
				end
			elseif NumFootswitches > NumJacks then
				needFlip = LastFlip -- Match flipness of last chunk -> footswitch
			else
				needFlip = not LastFlip -- Don't match -> jack
			end
		end

		-- Now that we know the correct flip, see if the stream needs split.
		-- If "too much" of the stream is *completely* crossed over, force a
		-- double-step there by splitting the stream to stay facing forward.
		-- Heuristic value (9) chosen by inspection on Subluminal - After Hours.
		local splitIndex -- Option<int>
		local splitFirstUncrossedStepIndex -- Option<Int>
		local numConsecutiveCrossed = 0
		for i, step in ipairs(StepsLR) do
			local stepIsCrossed = step == needFlip
			if not splitIndex then -- lua doesn't have `break` huh. ok
				if stepIsCrossed then
					numConsecutiveCrossed = numConsecutiveCrossed + 1
					if numConsecutiveCrossed == 9 then
						splitIndex = i - 8 -- beware the 1-index
					end
				else
					numConsecutiveCrossed = 0
				end
			elseif not splitFirstUncrossedStepIndex then
				-- Also search for the first un-crossed step after the fux section,
				-- which will be used below in the `splitIndex == 1` case.
				if not stepIsCrossed then
					splitFirstUncrossedStepIndex = i
				end
			end
		end

		if splitIndex then
			-- Note that since we take O(n) to compute `needFlip`, and then we might
			-- do repeated work scanning already-analyzed ranges of `StepsLR` during
			-- the recursive call here, it's technically possible for a worst case
			-- performance of O(n^2 / 18) if the whole chart fits this pattern.
			-- But this is expected to be pretty rare to happen even once so probably ok.
			-- TODO: Optimize the above by using a separate explicit counter for `nx`.
			if splitIndex == 1 then
				-- Prevent infinite splittage if the fux section starts immediately.
				-- In that case split instead at the first non-crossed step.
				-- The next index is guaranteed to be set in this case.
				splitIndex = splitFirstUncrossedStepIndex -- .unwrap()
			end

			local StepsLR1 = {}
			local StepsLR2 = {}
			for i, step in ipairs(StepsLR) do
				if i < splitIndex then
					StepsLR1[#StepsLR1+1] = step
				else
					StepsLR2[#StepsLR2+1] = step
				end
			end
			-- Recurse for each split half
			StepsLR = StepsLR1
			CommitStream(nil)
			LastRepeatedFoot = nil
			StepsLR = StepsLR2
			CommitStream(tieBreakFoot)
		else
			-- No heuristic doublestep splittage necessary. Update the stats.
			if needFlip then
				NumCrossovers = NumCrossovers + ns - nx
			else
				NumCrossovers = NumCrossovers + nx
			end

			if LastRepeatedFoot then
				if needFlip == LastFlip then
					NumFootswitches = NumFootswitches + 1
					if LastRepeatedFoot == "L" or LastRepeatedFoot == "R" then
						NumSideswitches = NumSideswitches + 1
					end
				else
					NumJacks = NumJacks + 1
				end
			end

			StepsLR = {}
			LastFlip = needFlip

			-- Merge the (flip-ambiguous) last-arrow tracking into the source of truth
			-- TODO(bracket) - Do we need to check if the `LastArrow`s are empty, like
			-- the hs version does? I hypothesize it actually makes no difference.
			-- NB: This can't just be `ns > 0` bc we want to update the TrueLastFoot
			-- even when there were just U/D steps (whereupon StepsLR would be empty).
			if AnyStepsSinceLastCommitStream then
				if needFlip then
					-- TrueLastFoot is a tristate so can't just copy the bool
					if LastFoot then TrueLastFoot = "L" else TrueLastFoot = "R" end
					TrueLastArrowL = LastArrowR
					TrueLastArrowR = LastArrowL
					-- TODO: "If we had to flip a stream right after a bracket jump,
					-- that'd make it retroactively unbracketable; if so cancel it"
					-- (...do i even believe this anymore? probs not...)
				else
					if LastFoot then TrueLastFoot = "R" else TrueLastFoot = "L" end
					TrueLastArrowL = LastArrowL
					TrueLastArrowR = LastArrowR
				end
			end
			AnyStepsSinceLastCommitStream = false
			LastArrowL = ""
			LastArrowR = ""
			JustBracketed = false
		end
	end

	for line in chartString:gmatch("[^%s*\r\n]+") do
		if line:match(RegexStep) then
			local step = ""
			if line:match(RegexL) then step = step .. "L" end
			if line:match(RegexD) then step = step .. "D" end
			if line:match(RegexU) then step = step .. "U" end
			if line:match(RegexR) then step = step .. "R" end

			if step:len() == 1 then
				-- Normal step
				if LastStep and step == LastStep then
					-- Jack or footswitch
					CommitStream(nil)
					LastRepeatedFoot = step
				end

				-- A normal streamy step
				LastStep = step
				-- Switch feet
				LastFoot = not LastFoot
				-- Record whether we stepped on a matching or crossed-over L/R arrow
				-- TODO: Check yes/not true/false left/right parity here (vs .hs/.cpps)
				if step == "L" then
					StepsLR[#StepsLR+1] = not LastFoot
				elseif step == "R" then
					StepsLR[#StepsLR+1] = LastFoot
				end
				AnyStepsSinceLastCommitStream = true
				-- Regardless, record what arrow the foot stepped on (for brackets l8r)
				if LastFoot then
					LastArrowR = step
				else
					LastArrowL = step
				end
			elseif step:len() > 1 then
				-- Jump
				-- TODO(bracket) - Make stream able to continue thru a bracket jump

				if step:len() == 2 then
					local isBracketLeft  = step:match("L[^R]")
					local isBracketRight = step:match("[^L]R")

					local tieBreakFoot = nil
					if isBracketLeft then
						tieBreakFoot = "L"
					elseif isBracketRight then
						tieBreakFoot = "R"
					end
					CommitStream(tieBreakFoot)
					LastStep = nil
					LastRepeatedFoot = nil

					if isBracketLeft or isBracketRight then
						-- Possibly bracketable
						if isBracketLeft and (not TrueLastFoot or TrueLastFoot == "R") then
							-- Check for interference from the right foot
							-- NB: This should be `intersect` in case of eg LU <-> LR
							-- But we dodge this by taking sub(2)/sub(1,1) down below.
							if not step:match(TrueLastArrowR) then
								NumBrackets = NumBrackets + 1
								-- Allow subsequent brackets to stream
								TrueLastFoot = "L"
								LastFoot = false
								-- This prevents e.g. "LD bracket, DR also bracket"
								-- NB: Take only the U or D arrow (cf above NB)
								TrueLastArrowL = step:sub(2)
								JustBracketed = true
							else
								-- Right foot is in the way; we have to step with both feet
								TrueLastFoot = nil
								TrueLastArrowL = "L"
								TrueLastArrowR = step:sub(2)
								LastArrowR = TrueLastArrowR
							end
							LastArrowL = TrueLastArrowL
						elseif isBracketRight and (not TrueLastFoot or TrueLastFoot == "L") then
							-- Check for interference from the left foot
							-- Symmetric logic; see comments above
							if not step:match(TrueLastArrowL) then
								NumBrackets = NumBrackets + 1
								TrueLastFoot = "R"
								LastFoot = true
								TrueLastArrowR = step:sub(1,1)
								JustBracketed = true
							else
								TrueLastFoot = nil
								TrueLastArrowL = step:sub(1,1)
								TrueLastArrowR = "R"
								LastArrowL = TrueLastArrowL
							end
							LastArrowR = TrueLastArrowR
						end
					else
						-- LR or DU
						if step == "DU" then
							-- Past footing influences which way the player can
							-- comfortably face while jumping DU
							local leftD  = TrueLastArrowL:match("D")
							local leftU  = TrueLastArrowL:match("U")
							local rightD = TrueLastArrowR:match("D")
							local rightU = TrueLastArrowR:match("U")
							-- The haskell version of this (decideDUFacing) is a
							-- little more strict, and asserts each foot can't be
							-- be on both D and U at once, but whatever.
							if (leftD and not rightD) or (rightU and not leftU) then
								TrueLastArrowL = "D"
								TrueLastArrowR = "U"
							elseif (leftU and not rightU) or (rightD and not leftD) then
								TrueLastArrowL = "U"
								TrueLastArrowR = "D"
							else
								TrueLastArrowL = "X"
								TrueLastArrowR = "X"
							end
						else
							-- Not going to bother thinking about spin-jumps ><
							TrueLastArrowL = "X"
							TrueLastArrowR = "X"
						end
						TrueLastFoot = nil
					end
				else
					CommitStream()
					LastStep = nil
					LastRepeatedFoot = nil
					-- Triple/quad - always gotta bracket these
					NumBrackets = NumBrackets + 1
					TrueLastFoot = nil
				end
			end
		end
	end
	CommitStream(nil)

	return NumCrossovers, NumFootswitches, NumSideswitches, NumJacks, NumBrackets
end

-- ----------------------------------------------------------------

local MaybeCopyFromOppositePlayer = function(pn, filename, stepsType, difficulty, description)
	local opposite_player = pn == "P1" and "P2" or "P1"

	-- Check if we already have the data stored in the opposite player's cache.
	if (SL[opposite_player].Streams.Filename == filename and
			SL[opposite_player].Streams.StepsType == stepsType and
			SL[opposite_player].Streams.Difficulty == difficulty and
			SL[opposite_player].Streams.Description == description) then
		-- If so then just copy everything over.
		SL[pn].Streams.NotesPerMeasure = SL[opposite_player].Streams.NotesPerMeasure
		SL[pn].Streams.EquallySpacedPerMeasure = SL[opposite_player].Streams.EquallySpacedPerMeasure
		SL[pn].Streams.PeakNPS = SL[opposite_player].Streams.PeakNPS
		SL[pn].Streams.NPSperMeasure = SL[opposite_player].Streams.NPSperMeasure
		SL[pn].Streams.ColumnCues = SL[opposite_player].Streams.ColumnCues
		SL[pn].Streams.Hash = SL[opposite_player].Streams.Hash

		SL[pn].Streams.Crossovers = SL[opposite_player].Streams.Crossovers
		SL[pn].Streams.Footswitches = SL[opposite_player].Streams.Footswitches
		SL[pn].Streams.Sideswitches = SL[opposite_player].Streams.Sideswitches
		SL[pn].Streams.Jacks = SL[opposite_player].Streams.Jacks
		SL[pn].Streams.Brackets = SL[opposite_player].Streams.Brackets

		SL[pn].Streams.Filename = SL[opposite_player].Streams.Filename
		SL[pn].Streams.StepsType = SL[opposite_player].Streams.StepsType
		SL[pn].Streams.Difficulty = SL[opposite_player].Streams.Difficulty
		SL[pn].Streams.Description = SL[opposite_player].Streams.Description

		return true
	else
		return false
	end
end
		
ParseChartInfo = function(steps, pn)
	-- The filename for these steps in the StepMania cache 
	local filename = steps:GetFilename()
	-- StepsType, a string like "dance-single" or "pump-double"
	local stepsType = ToEnumShortString( steps:GetStepsType() ):gsub("_", "-"):lower()
	-- Difficulty, a string like "Beginner" or "Challenge"
	local difficulty = ToEnumShortString( steps:GetDifficulty() )
	-- An arbitary but unique string provided by the stepartist, needed here to identify Edit charts
	local description = steps:GetDescription()

	-- If we've copied from the other player then we're done.
	if MaybeCopyFromOppositePlayer(pn, filename, stepsType, difficulty, description) then
		return
	end

	-- Only parse the file if it's not what's already stored in SL Cache.
	if (SL[pn].Streams.Filename ~= filename or
			SL[pn].Streams.StepsType ~= stepsType or
			SL[pn].Streams.Difficulty ~= difficulty or
			SL[pn].Streams.Description ~= description) then
		local simfileString, fileType = GetSimfileString( steps )
		local parsed = false

		if simfileString then
			-- Parse out just the contents of the notes
			local chartString, BPMs = GetSimfileChartString(simfileString, stepsType, difficulty, description, fileType)
			if chartString ~= nil and BPMs ~= nil then
				-- We use 16 characters for the V3 GrooveStats hash.
				local Hash = BinaryToHex(CRYPTMAN:SHA1String(chartString..BPMs)):sub(1, 16)

				-- Append the semi-colon at the end so it's easier for GetMeasureInfo to get the contents
				-- of the last measure.
				chartString = chartString .. '\n;'
				-- Which measures have enough notes to be considered as part of a stream?
				-- We can also extract the PeakNPS and the NPSperMeasure table info in the same pass.
				-- The chart string is minimized at this point (via GetSimfileChartString).
				local NotesPerMeasure, PeakNPS, NPSperMeasure, ColumnCues, EquallySpacedPerMeasure = GetMeasureInfo(steps, chartString)

				-- Which sequences of measures are considered a stream?
				SL[pn].Streams.NotesPerMeasure = NotesPerMeasure
				SL[pn].Streams.EquallySpacedPerMeasure = EquallySpacedPerMeasure
				SL[pn].Streams.PeakNPS = PeakNPS
				SL[pn].Streams.NPSperMeasure = NPSperMeasure
				SL[pn].Streams.ColumnCues = ColumnCues
				SL[pn].Streams.Hash = Hash

				local Crossovers, Footswitches, Sideswitches, Jacks, Brackets = GetTechniques(chartString)
				SL[pn].Streams.Crossovers = Crossovers
				SL[pn].Streams.Footswitches = Footswitches
				SL[pn].Streams.Sideswitches = Sideswitches
				SL[pn].Streams.Jacks = Jacks
				SL[pn].Streams.Brackets = Brackets

				SL[pn].Streams.Filename = filename
				SL[pn].Streams.StepsType = stepsType
				SL[pn].Streams.Difficulty = difficulty
				SL[pn].Streams.Description = description

				parsed = true
			end
		end

		-- Clear stream data if we can't parse the chart
		if not parsed then
			SL[pn].Streams.NotesPerMeasure = {}
			SL[pn].Streams.EquallySpacedPerMeasure = {}
			SL[pn].Streams.PeakNPS = 0
			SL[pn].Streams.NPSperMeasure = {}
			SL[pn].Streams.Hash = ''

			SL[pn].Streams.Crossovers = 0
			SL[pn].Streams.Footswitches = 0
			SL[pn].Streams.Sideswitches = 0
			SL[pn].Streams.Jacks = 0
			SL[pn].Streams.Brackets = 0

			SL[pn].Streams.Filename = filename
			SL[pn].Streams.StepsType = stepsType
			SL[pn].Streams.Difficulty = difficulty
			SL[pn].Streams.Description = description
		end
	end
end
