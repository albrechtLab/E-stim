function StimValidationGUI()
% StimValidationGUI  — Electrical stimulation waveform validation tool
%
% Reads an experiment settings file, programs the StimJim via serial,
% streams fast (20 kHz) waveform data from a DataLogger Arduino for each
% stimulus pattern, displays voltage and current traces, and saves results.
%
% DataLogger command protocol (sent in sequence before each capture):
%   "i50"  — set sample interval to 50 µs (20 kHz)
%   "n2"   — 2 analogue channels
%   "L0"   — no trigger limit (free-run)
%   "m"    — trigger a fast memory capture (~2000 points streamed back)
%
% StimJim command protocol:
%   S<n>,<mode0>,<mode1>,<period_us>,<duration_us>; <a0>,<a1>,<dur>; ...
%   T<n>   — trigger pattern n
%   T-1    — force stop
%
% Calibration defaults (raw ADC units → physical):
%   Voltage : (raw - 1952) / 41       [V]
%   Current : (raw - 2052) / 843      [mA]

    %% ----------------------------------------------------------------
    %  Constants
    %% ----------------------------------------------------------------
    STIM_DURATION_US   = 500000;   % override pulse-train duration (µs)
    TOTAL_TIME_PER_PAT = 1.0;      % seconds between triggers
    LOGGER_INIT_PAUSE  = 3.0;      % s between logger init commands
    SERIAL_BAUD        = 115200;
    ESTIM_FOLDER       = 'D:/Data/E_stim_waveforms';

    DEFAULT_V_OFFSET   = 1952;
    DEFAULT_V_SCALE    = 41;       % ADC units per V
    DEFAULT_I_OFFSET   = 2052;
    DEFAULT_I_SCALE    = 843;      % ADC units per mA

    %% ----------------------------------------------------------------
    %  Shared state
    %% ----------------------------------------------------------------
    settingsFile  = '';
    patterns      = struct([]);   % parsed stim patterns
    resultData    = struct([]);   % captured waveforms
    loggerReady   = false;
    sjPort        = [];           % StimJim serialport object
    dlPort        = [];           % DataLogger serialport object

    %% ----------------------------------------------------------------
    %  Build GUI
    %% ----------------------------------------------------------------
    fig = uifigure('Name','StimJim Waveform Validator','Position',[100 80 1200 750]);
    fig.CloseRequestFcn = @onClose;

    gl = uigridlayout(fig,[1 2]);
    gl.ColumnWidth = {'1x','2x'};

    %% --- LEFT PANEL ---------------------------------------------------
    leftPanel = uipanel(gl,'Title','Control','FontWeight','bold');
    lg = uigridlayout(leftPanel,[14 2]);
    lg.RowHeight   = {30,30,30,30,30,30,30,22,22,22,22,30,30,'1x'};
    lg.ColumnWidth = {'1x','1x'};

    % -- Settings file row
    uilabel(lg,'Text','Settings file:','FontWeight','bold',...
        'Layout',struct('Row',1,'Column',1));
    btnFile = uibutton(lg,'Text','Browse…','Layout',struct('Row',1,'Column',2),...
        'ButtonPushedFcn',@browseFile);

    fileLabel = uilabel(lg,'Text','(none)','WordWrap','on',...
        'Layout',struct('Row',2,'Column',[1 2]));

    % -- COM port dropdowns
    uilabel(lg,'Text','StimJim COM:','Layout',struct('Row',3,'Column',1));
    ddStimjim = uidropdown(lg,'Items',{},'Layout',struct('Row',3,'Column',2));

    uilabel(lg,'Text','DataLogger COM:','Layout',struct('Row',4,'Column',1));
    ddLogger = uidropdown(lg,'Items',{},'Layout',struct('Row',4,'Column',2));

    btnRefreshPorts = uibutton(lg,'Text','Refresh ports',...
        'Layout',struct('Row',5,'Column',[1 2]),...
        'ButtonPushedFcn',@(~,~) refreshPorts());

    % -- Load patterns button
    btnLoad = uibutton(lg,'Text','Load patterns into StimJim',...
        'Layout',struct('Row',6,'Column',[1 2]),...
        'BackgroundColor',[0.85 0.85 0.85],...
        'ButtonPushedFcn',@loadPatterns);

    lblLoadStatus = uilabel(lg,'Text','','HorizontalAlignment','center',...
        'Layout',struct('Row',7,'Column',[1 2]));

    % -- Calibration boxes
    uilabel(lg,'Text','— Calibration —','HorizontalAlignment','center',...
        'FontWeight','bold','Layout',struct('Row',8,'Column',[1 2]));

    uilabel(lg,'Text','V offset:','Layout',struct('Row',9,'Column',1));
    efVoff = uieditfield(lg,'numeric','Value',DEFAULT_V_OFFSET,...
        'Layout',struct('Row',9,'Column',2));

    uilabel(lg,'Text','V scale (u/V):','Layout',struct('Row',10,'Column',1));
    efVscl = uieditfield(lg,'numeric','Value',DEFAULT_V_SCALE,...
        'Layout',struct('Row',10,'Column',2));

    uilabel(lg,'Text','I offset:','Layout',struct('Row',11,'Column',1));
    efIoff = uieditfield(lg,'numeric','Value',DEFAULT_I_OFFSET,...
        'Layout',struct('Row',11,'Column',2));

    uilabel(lg,'Text','I scale (u/mA):','Layout',struct('Row',12,'Column',1));
    efIscl = uieditfield(lg,'numeric','Value',DEFAULT_I_SCALE,...
        'Layout',struct('Row',12,'Column',2));

    % -- Action buttons
    btnStart = uibutton(lg,'Text','▶  Start testing',...
        'Layout',struct('Row',13,'Column',[1 2]),...
        'BackgroundColor',[0.2 0.7 0.3],'FontColor','white','FontWeight','bold',...
        'Enable','off',...
        'ButtonPushedFcn',@startTesting);

    bg = uigridlayout(lg,[1 2]);
    bg.Layout = struct('Row',14,'Column',[1 2]);
    bg.Padding = [0 0 0 0];
    bg.ColumnWidth = {'1x','1x'};
    btnSaveData = uibutton(bg,'Text','Save data','Enable','off',...
        'ButtonPushedFcn',@saveData);
    btnSaveFig  = uibutton(bg,'Text','Save graphs','Enable','off',...
        'ButtonPushedFcn',@saveFigures);

    %% --- RIGHT PANEL --------------------------------------------------
    rightPanel = uipanel(gl,'Title','Results','FontWeight','bold');
    rg = uigridlayout(rightPanel,[2 2]);
    rg.RowHeight   = {'3x','1x'};
    rg.ColumnWidth = {'4x','1x'};

    % Axes
    axV = uiaxes(rg);  axV.Layout = struct('Row',1,'Column',1);
    axI = uiaxes(rg);  axI.Layout = struct('Row',2,'Column',1);

    xlabel(axV,'Time (ms)');  ylabel(axV,'Voltage (V)');
    xlabel(axI,'Time (ms)');  ylabel(axI,'Current (mA)');
    title(axV,'Voltage');     title(axI,'Current');
    axV.XGrid = 'on';  axV.YGrid = 'on';
    axI.XGrid = 'on';  axI.YGrid = 'on';
    hold(axV,'on');    hold(axI,'on');

    % Pattern list box
    uilabel(rg,'Text','Patterns','HorizontalAlignment','center',...
        'FontWeight','bold','Layout',struct('Row',1,'Column',2));
    lbPatterns = uilistbox(rg,'Items',{},...
        'Layout',struct('Row',2,'Column',2),...
        'ValueChangedFcn',@onPatternSelect);

    % Stimulus command display (scrollable text area, spans full width)
    % placed below axes — we add it as a separate uipanel inside rg row 2 col 1
    cmdPanel = uipanel(rg,'Title','Stimulus commands');
    cmdPanel.Layout = struct('Row',2,'Column',1);
    taCmd = uitextarea(cmdPanel,'Editable','off','Value',{'(load settings file to populate)'},...
        'Position',[5 5 1 1]); % position overridden by SizeChangedFcn below
    cmdPanel.SizeChangedFcn = @(src,~) set(taCmd,'Position',[5 5 src.InnerPosition(3)-10 src.InnerPosition(4)-10]);

    %% ----------------------------------------------------------------
    %  Initialise port list
    %% ----------------------------------------------------------------
    refreshPorts();

    %% ================================================================
    %  CALLBACKS
    %% ================================================================

    function browseFile(~,~)
        [fn,fp] = uigetfile('*.txt','Select experiment settings file');
        if isequal(fn,0), return; end
        settingsFile = fullfile(fp,fn);
        fileLabel.Text = settingsFile;
        parseSettingsFile();
    end

    % ----------------------------------------------------------------
    function refreshPorts()
        ports = listArduinoPorts();
        if isempty(ports), ports = {'(none)'}; end
        ddStimjim.Items = ports;
        ddLogger.Items  = ports;
        if numel(ports) >= 2
            ddLogger.Value = ports{2};
        end
    end

    % ----------------------------------------------------------------
    function parseSettingsFile()
        if isempty(settingsFile), return; end
        try
            lines = readlines(settingsFile);    % MATLAB R2020b+
        catch
            fid = fopen(settingsFile,'r');
            raw = fread(fid,'*char')';
            fclose(fid);
            lines = strsplit(raw,'\n');
            lines = string(lines);
        end

        % Pattern definitions start at line index 12 (1-based),
        % i.e. lines{12} onward.  Digit-labelled lines are stim patterns.
        pats = struct([]);
        cmdStrs = {};
        for k = 12:numel(lines)
            ln = strtrim(lines{k});
            if numel(ln) < 3 || ln(2) ~= ')', continue; end
            label = ln(1);
            if ~isstrprop(label,'digit'), continue; end
            pNum = str2double(label);

            % Strip comment
            ci = strfind(ln,' % ');
            if ~isempty(ci), ln = strtrim(ln(1:ci(1)-1)); end

            % Body after "N) "
            body = strtrim(ln(3:end));

            % StimJim command is after " | "
            pi2 = strfind(body,' | ');
            if isempty(pi2), continue; end
            sjCmd = strtrim(body(pi2(1)+3:end));

            % Must start with S
            if isempty(sjCmd) || sjCmd(1) ~= 'S', continue; end

            % Rebuild with correct pattern number and overridden duration
            rebuilt = rebuildSCommand(sjCmd, pNum, STIM_DURATION_US);
            if isempty(rebuilt), continue; end

            entry.patternNum  = pNum;
            entry.originalCmd = sjCmd;
            entry.sendCmd     = rebuilt;
            if isempty(pats)
                pats = entry;
            else
                pats(end+1) = entry;           %#ok<AGROW>
            end
            cmdStrs{end+1} = sprintf('Pattern %d: %s', pNum, rebuilt); %#ok<AGROW>
        end

        patterns = pats;

        if isempty(patterns)
            taCmd.Value = {'No stimulus patterns found in settings file.'};
            uialert(fig,'No digit-labelled StimJim S commands found.','Parse error');
            return;
        end

        taCmd.Value = cmdStrs(:);
        btnLoad.Enable = 'on';
        lblLoadStatus.Text = sprintf('%d pattern(s) parsed.', numel(patterns));
    end

    % ----------------------------------------------------------------
    function loadPatterns(~,~)
        if isempty(patterns)
            uialert(fig,'Parse a settings file first.','No patterns');
            return;
        end
        % Open StimJim port
        sjPortName = ddStimjim.Value;
        if strcmp(sjPortName,'(none)')
            uialert(fig,'Select a StimJim COM port.','No port');
            return;
        end
        try
            if ~isempty(sjPort) && isvalid(sjPort), delete(sjPort); end
            sjPort = serialport(sjPortName, SERIAL_BAUD);
            configureTerminator(sjPort,'CR/LF');
            sjPort.Timeout = 5;
        catch ME
            uialert(fig,ME.message,'Serial error'); return;
        end

        lblLoadStatus.Text = 'Programming StimJim…';
        drawnow;

        allOk = true;
        for p = 1:numel(patterns)
            cmd = patterns(p).sendCmd;
            writeline(sjPort, cmd);
            pause(1.5);
            resp = '';
            while sjPort.NumBytesAvailable > 0
                resp = [resp, readline(sjPort)]; %#ok<AGROW>
            end
            ok = contains(resp,'V') || contains(resp,'mV') || contains(resp,'uA');
            if ok
                lblLoadStatus.Text = sprintf('Sent pattern %d/%d OK', p, numel(patterns));
            else
                lblLoadStatus.Text = sprintf('WARNING: No ack for pattern %d', patterns(p).patternNum);
                allOk = false;
            end
            drawnow;
        end

        % Initialise DataLogger
        dlPortName = ddLogger.Value;
        if strcmp(dlPortName,'(none)')
            uialert(fig,'Select a DataLogger COM port.','No port');
            return;
        end
        try
            if ~isempty(dlPort) && isvalid(dlPort), delete(dlPort); end
            dlPort = serialport(dlPortName, SERIAL_BAUD);
            configureTerminator(dlPort,'LF');
            dlPort.Timeout = 10;
        catch ME
            uialert(fig,ME.message,'Serial error'); return;
        end

        lblLoadStatus.Text = 'Initialising DataLogger (i50)…'; drawnow;
        writeline(dlPort,'i50');  pause(LOGGER_INIT_PAUSE);

        lblLoadStatus.Text = 'Initialising DataLogger (n2)…';  drawnow;
        writeline(dlPort,'n2');   pause(LOGGER_INIT_PAUSE);

        lblLoadStatus.Text = 'Initialising DataLogger (L0)…';  drawnow;
        writeline(dlPort,'L0');   pause(LOGGER_INIT_PAUSE);

        loggerReady = true;

        if allOk
            lblLoadStatus.Text = 'All patterns loaded. Logger ready.';
            btnLoad.BackgroundColor = [0.3 0.8 0.3];
        else
            lblLoadStatus.Text = 'Patterns loaded with warnings. Logger ready.';
            btnLoad.BackgroundColor = [1.0 0.8 0.2];
        end
        btnStart.Enable = 'on';
        drawnow;
    end

    % ----------------------------------------------------------------
    function startTesting(~,~)
        if isempty(patterns) || ~loggerReady
            uialert(fig,'Load patterns first.','Not ready'); return;
        end
        btnStart.Enable = 'off';
        resultData = struct([]);
        timestamp  = datetime('now','Format','yyyy-MM-dd_HH-mm-ss');

        for p = 1:numel(patterns)
            if ~isvalid(fig), break; end
            pNum   = patterns(p).patternNum;
            trigCmd = sprintf('T%d', pNum);

            lblLoadStatus.Text = sprintf('Testing pattern %d/%d…', p, numel(patterns));
            drawnow;

            % Trigger StimJim
            writeline(sjPort, trigCmd);

            % Immediately trigger DataLogger fast capture
            writeline(dlPort, 'm');

            % Read streamed data back from DataLogger
            raw = readLoggerCapture(dlPort);

            % Store result
            entry.patternNum  = pNum;
            entry.sendCmd     = patterns(p).sendCmd;
            entry.triggerCmd  = trigCmd;
            entry.timestamp   = timestamp;
            entry.rawData     = raw;   % Nx2: [ch1, ch2]
            if isempty(resultData)
                resultData = entry;
            else
                resultData(end+1) = entry; %#ok<AGROW>
            end

            % Update list box
            items = lbPatterns.Items;
            items{end+1} = sprintf('Pattern %d', pNum);
            lbPatterns.Items = items;
            lbPatterns.Value = items{end};

            % Plot immediately
            plotPattern(p);

            % Wait remainder of total slot
            pause(max(0, TOTAL_TIME_PER_PAT - 0.5));
        end

        % Force StimJim stop
        writeline(sjPort,'T-1');

        lblLoadStatus.Text = sprintf('Done. %d pattern(s) captured.', numel(resultData));
        btnStart.Enable  = 'on';
        btnSaveData.Enable = 'on';
        btnSaveFig.Enable  = 'on';
        drawnow;
    end

    % ----------------------------------------------------------------
    function onPatternSelect(~,~)
        idx = find(strcmp(lbPatterns.Items, lbPatterns.Value));
        if ~isempty(idx) && idx <= numel(resultData)
            plotPattern(idx);
        end
    end

    % ----------------------------------------------------------------
    function plotPattern(idx)
        if idx > numel(resultData), return; end
        d = resultData(idx);
        if isempty(d.rawData), return; end

        Voff  = efVoff.Value;  Vscl = efVscl.Value;
        Ioff  = efIoff.Value;  Iscl = efIscl.Value;

        nPts  = size(d.rawData,1);
        t_us  = (0:nPts-1)' * 50;          % 50 µs per sample at 20 kHz
        t_ms  = t_us / 1000;

        Vcal  = (d.rawData(:,1) - Voff) / Vscl;
        Ical  = (d.rawData(:,2) - Ioff) / Iscl;
        zero  = zeros(nPts,1);

        cla(axV); hold(axV,'on');
        fill(axV,[t_ms; flipud(t_ms)],[Vcal; flipud(zero)],[0.2 0.5 0.9],...
            'FaceAlpha',0.35,'EdgeColor','none');
        plot(axV, t_ms, Vcal, 'Color',[0.1 0.3 0.8],'LineWidth',1.5);
        plot(axV, t_ms, zero, 'k-','LineWidth',0.5);
        ylabel(axV,'Voltage (V)');
        xlabel(axV,'Time (ms)');
        title(axV, sprintf('Pattern %d — Voltage', d.patternNum));
        axV.XGrid = 'on'; axV.YGrid = 'on';

        cla(axI); hold(axI,'on');
        fill(axI,[t_ms; flipud(t_ms)],[Ical; flipud(zero)],[0.9 0.3 0.2],...
            'FaceAlpha',0.35,'EdgeColor','none');
        plot(axI, t_ms, Ical, 'Color',[0.8 0.1 0.1],'LineWidth',1.5);
        plot(axI, t_ms, zero, 'k-','LineWidth',0.5);
        ylabel(axI,'Current (mA)');
        xlabel(axI,'Time (ms)');
        title(axI, sprintf('Pattern %d — Current', d.patternNum));
        axI.XGrid = 'on'; axI.YGrid = 'on';

        drawnow;
    end

    % ----------------------------------------------------------------
    function saveData(~,~)
        if isempty(resultData)
            uialert(fig,'No data to save.','Empty'); return;
        end
        if ~isfolder(ESTIM_FOLDER), mkdir(ESTIM_FOLDER); end
        ts   = char(resultData(1).timestamp);
        fname = fullfile(ESTIM_FOLDER, ['StimValidation_' ts '.mat']);
        save(fname,'resultData');
        lblLoadStatus.Text = ['Data saved: ' fname];
        uialert(fig,['Saved to: ' fname],'Saved','Icon','success');
    end

    % ----------------------------------------------------------------
    function saveFigures(~,~)
        if isempty(resultData)
            uialert(fig,'No data to save.','Empty'); return;
        end
        if ~isfolder(ESTIM_FOLDER), mkdir(ESTIM_FOLDER); end
        ts = char(resultData(1).timestamp);

        for idx = 1:numel(resultData)
            plotPattern(idx);
            drawnow;

            % Capture current axes into a standalone figure
            fh = figure('Visible','off','Position',[0 0 900 500]);
            axV2 = subplot(2,1,1,'Parent',fh);
            axI2 = subplot(2,1,2,'Parent',fh);

            d     = resultData(idx);
            nPts  = size(d.rawData,1);
            t_ms  = (0:nPts-1)' * 50 / 1000;
            Vcal  = (d.rawData(:,1) - efVoff.Value) / efVscl.Value;
            Ical  = (d.rawData(:,2) - efIoff.Value) / efIscl.Value;
            zero  = zeros(nPts,1);

            hold(axV2,'on');
            fill(axV2,[t_ms; flipud(t_ms)],[Vcal; flipud(zero)],[0.2 0.5 0.9],...
                'FaceAlpha',0.35,'EdgeColor','none');
            plot(axV2, t_ms, Vcal,'Color',[0.1 0.3 0.8],'LineWidth',1.5);
            yline(axV2,0,'k-','LineWidth',0.5);
            ylabel(axV2,'Voltage (V)'); xlabel(axV2,'Time (ms)');
            title(axV2, sprintf('Pattern %d — Voltage', d.patternNum));
            grid(axV2,'on');

            hold(axI2,'on');
            fill(axI2,[t_ms; flipud(t_ms)],[Ical; flipud(zero)],[0.9 0.3 0.2],...
                'FaceAlpha',0.35,'EdgeColor','none');
            plot(axI2, t_ms, Ical,'Color',[0.8 0.1 0.1],'LineWidth',1.5);
            yline(axI2,0,'k-','LineWidth',0.5);
            ylabel(axI2,'Current (mA)'); xlabel(axI2,'Time (ms)');
            title(axI2, sprintf('Pattern %d — Current', d.patternNum));
            grid(axI2,'on');

            base = fullfile(ESTIM_FOLDER, sprintf('StimValidation_%s_P%d', ts, d.patternNum));
            savefig(fh, [base '.fig']);
            saveas(fh,  [base '.svg']);
            close(fh);
        end
        lblLoadStatus.Text = sprintf('Graphs saved (%d files).', numel(resultData));
        uialert(fig,sprintf('%d figure(s) saved to %s', numel(resultData), ESTIM_FOLDER),...
            'Saved','Icon','success');
    end

    % ----------------------------------------------------------------
    function onClose(~,~)
        try
            if ~isempty(sjPort) && isvalid(sjPort)
                writeline(sjPort,'T-1');
                delete(sjPort);
            end
        catch, end
        try
            if ~isempty(dlPort) && isvalid(dlPort), delete(dlPort); end
        catch, end
        delete(fig);
    end

end % StimValidationGUI


%% ====================================================================
%  LOCAL HELPER FUNCTIONS
%% ====================================================================

function ports = listArduinoPorts()
% Return cell array of serial port names likely associated with Arduinos.
    ports = {};
    try
        info = serialportlist('available');
        % On Windows prefer COM ports; on Mac/Linux prefer /dev/cu.usbmodem etc.
        for k = 1:numel(info)
            pname = char(info(k));
            if contains(pname,'COM','IgnoreCase',true) || ...
               contains(pname,'usbmodem','IgnoreCase',true) || ...
               contains(pname,'usbserial','IgnoreCase',true)
                ports{end+1} = pname; %#ok<AGROW>
            end
        end
        if isempty(ports)
            % Fallback: return all available ports
            for k = 1:numel(info)
                ports{end+1} = char(info(k)); %#ok<AGROW>
            end
        end
    catch
        ports = {};
    end
end

% ---------------------------------------------------------------------
function rebuilt = rebuildSCommand(originalCmd, patternNumber, newDurationUs)
% Rebuild a StimJim S command, replacing the pattern slot index with
% patternNumber and field index 4 (duration_us) with newDurationUs.
%
% Format: S<n>,<mode0>,<mode1>,<period_us>,<duration_us>; stages…
%
% Returns '' if the command cannot be parsed.
    rebuilt = '';
    semi = strfind(originalCmd,';');
    if isempty(semi), return; end

    header = strtrim(originalCmd(1:semi(1)-1));   % e.g. "S0,0,1,1000,100000"
    stages = originalCmd(semi(1):end);            % "; 100,-100,100; …"

    fields = strsplit(header,',');
    if numel(fields) < 5, return; end

    fields{1} = sprintf('S%d', patternNumber);    % replace slot index
    fields{5} = sprintf('%d',  newDurationUs);    % replace duration

    rebuilt = [strjoin(fields,','), stages];
end

% ---------------------------------------------------------------------
function raw = readLoggerCapture(dlPort)
% Read the fast-capture stream from the DataLogger after an "m" command.
%
% The DataLogger streams lines of comma-separated integers until it sends
% a blank line or a line starting with "Done" / "End".  Each non-empty
% line contains one sample: ch1,ch2  (two raw ADC values).
%
% Returns an Nx2 matrix of raw values (double).
    raw  = [];
    tEnd = tic;
    while toc(tEnd) < 10     % 10 s hard timeout
        if dlPort.NumBytesAvailable > 0 || toc(tEnd) < 0.5
            try
                ln = readline(dlPort);
                ln = strtrim(ln);
            catch
                break;
            end
            % Terminal conditions
            if isempty(ln) || strcmpi(ln,'done') || strcmpi(ln,'end')
                break;
            end
            % Parse sample line
            vals = str2double(strsplit(ln,','));
            if numel(vals) >= 2 && ~any(isnan(vals(1:2)))
                raw(end+1,:) = vals(1:2); %#ok<AGROW>
            end
        else
            pause(0.005);
        end
    end
    if isempty(raw)
        raw = zeros(0,2);
    end
end
