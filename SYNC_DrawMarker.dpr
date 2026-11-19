library SYNC_DrawMarker;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only

{$ALIGN 8}

uses
  System.SysUtils, Winapi.Windows,
  AviUtl2FilterTypes in 'Source\Lib\AviUtl2FilterTypes.pas',
  PluginFilterTable in 'Source\Lib\FilterTable\PluginFilterTable.pas',
  DrawMarker_Capture in 'Source\Plugin\Filter\DrawMarker_Capture.pas',
  DrawMarker_Model in 'Source\Common\DrawMarker_Model.pas',
  DrawMarker_Curves in 'Source\Common\DrawMarker_Curves.pas',
  DrawMarker_Renderer in 'Source\Common\DrawMarker_Renderer.pas',
  DrawMarker_Editor in 'Source\UI\DrawMarker_Editor.pas',
  SYNC_DrawMarker_FilterPlugin in 'Source\Plugin\Filter\SYNC_DrawMarker_FilterPlugin.pas';

{$R *.res}

function RequiredVersion: Cardinal; cdecl;
begin
  Result := RequiredHost;
end;

function InitializePlugin(Version: Cardinal): Byte; cdecl;
begin
  Result := 0;
  if Version < RequiredHost then Exit;
  try
    InitializeMarker;
    Result := 1;
  except
    on E: Exception do OutputDebugString(PChar('SYNC_DrawMarker initialize: ' + E.Message));
  end;
end;

procedure RegisterPlugin(Host: PHOST_APP_TABLE); cdecl;
begin
  try
    if Host = nil then Exit;
    Host^.SetPluginInformation(PluginInfo);
    RegisterMarker(Host);
  except
    on E: Exception do OutputDebugString(PChar('SYNC_DrawMarker register: ' + E.Message));
  end;
end;

procedure UninitializePlugin; cdecl;
begin
  try
    ShutdownMarker;
  except
  end;
end;

exports
  RequiredVersion name 'RequiredVersion',
  InitializePlugin name 'InitializePlugin',
  RegisterPlugin name 'RegisterPlugin',
  UninitializePlugin name 'UninitializePlugin';

begin
end.
