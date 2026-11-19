unit AviUtl2FilterTypes;

// Copyright (c) 2026 VRAMの魔術師
// SPDX-License-Identifier: GPL-3.0-only
// SDK declarations: Copyright (c) 2025 Kenkun; see ThirdParty/LICENSE.AviUtl2-SDK.txt (MIT).

// AviUtl2 フィルタープラグイン登録に必要な最小ABI定義。

{$ALIGN 8}

interface

type
  LPCWSTR = PWideChar;
  OBJECT_HANDLE = Pointer;
  EFFECT_HANDLE = Pointer;

  PEDIT_SECTION = ^TEDIT_SECTION;
  TFilterItemButtonCallback = procedure(Edit: PEDIT_SECTION); cdecl;
  TFilterItemButtonCallback2 = procedure(Edit: PEDIT_SECTION;
    Obj: OBJECT_HANDLE; Effect, Item: LPCWSTR); cdecl;
  TCountObjectEffectFunc = function(Obj: OBJECT_HANDLE;
    Effect: LPCWSTR): Integer; cdecl;
  TOBJECT_LAYER_FRAME = record
    Layer: Integer;
    StartFrame: Integer;
    EndFrame: Integer;
  end;
  TGetObjectLayerFrameFunc = function(
    Obj: OBJECT_HANDLE): TOBJECT_LAYER_FRAME; cdecl;
  TSetObjectItemValueFunc = function(Obj: OBJECT_HANDLE; Effect: LPCWSTR;
    Item: LPCWSTR; Value: PAnsiChar): Boolean; cdecl;
  TGetObjectItemValueFunc = function(Obj: OBJECT_HANDLE; Effect: LPCWSTR;
    Item: LPCWSTR): PAnsiChar; cdecl;
  TGetFocusObjectFunc = function: OBJECT_HANDLE; cdecl;
  TFindObjectFunc = function(Layer,Frame: Integer): OBJECT_HANDLE; cdecl;
  TSetObjectNameFunc = procedure(Obj: OBJECT_HANDLE; Name: LPCWSTR); cdecl;

  // ボタンコールバックで、選択中オブジェクトのGUI項目と表示名を変更する編集API。
  TEDIT_SECTION = record
    Info: Pointer;
    CreateObjectFromAlias: Pointer;
    FindObject: TFindObjectFunc;
    CountObjectEffect: TCountObjectEffectFunc;
    GetObjectLayerFrame: TGetObjectLayerFrameFunc;
    GetObjectAlias: Pointer;
    GetObjectItemValue: TGetObjectItemValueFunc;
    SetObjectItemValue: TSetObjectItemValueFunc;
    MoveObject: Pointer;
    DeleteObject: Pointer;
    GetFocusObject: TGetFocusObjectFunc;
    SetFocusObject: Pointer;
    GetProjectFile: Pointer;
    GetSelectedObject: Pointer;
    GetSelectedObjectNum: Pointer;
    GetMouseLayerFrame: Pointer;
    PosToLayerFrame: Pointer;
    IsSupportMediaFile: Pointer;
    GetMediaInfo: Pointer;
    CreateObjectFromMediaFile: Pointer;
    CreateObject: Pointer;
    SetCursorLayerFrame: procedure(Layer, Frame: Integer); cdecl;
    SetDisplayLayerFrame: Pointer;
    SetSelectRange: Pointer;
    SetGridBpm: Pointer;
    GetObjectName: Pointer;
    SetObjectName: TSetObjectNameFunc;
    // plugin2.h (SDK 2026-11-14): preserve all intervening ABI slots.
    LayerNameThroughDeprecatedSetBpm: array[27..49] of Pointer;
    FindEffect: function(Obj: OBJECT_HANDLE; Name: LPCWSTR): EFFECT_HANDLE; cdecl;
    GetEffectListThroughSetEffectLock: array[51..56] of Pointer;
    GetEffectItemValue: function(Effect: EFFECT_HANDLE; Item: LPCWSTR): PAnsiChar; cdecl;
    SetEffectItemValue: function(Effect: EFFECT_HANDLE; Item: LPCWSTR;
      Value: PAnsiChar): Boolean; cdecl;
    GetEffectTrackValue: Pointer;
    GetEffectCheckValueThroughMoveEffect: array[60..69] of Pointer;
    GetEffectDataValue: function(Effect: EFFECT_HANDLE; Item: LPCWSTR;
      Data: Pointer; Size: Integer): Integer; cdecl;
    SetEffectDataValue: function(Effect: EFFECT_HANDLE; Item: LPCWSTR;
      Data: Pointer; Size: Integer): Boolean; cdecl;
    SetEditedState: procedure; cdecl;
    MarkFrameListThroughSetObjectFlag: array[73..80] of Pointer;
    GetObjectID: function(Obj: OBJECT_HANDLE): Int64; cdecl;
    GetEffectID: function(Effect: EFFECT_HANDLE): Int64; cdecl;
  end;

  PSCENE_INFO = ^TSCENE_INFO;
  TSCENE_INFO = record
    Width, Height: Integer;
    Rate, Scale: Integer;
    SampleRate: Integer;
    ID, OriginID, Flag: Integer;
    RenderingID: Int64;
  end;

  POBJECT_INFO = ^TOBJECT_INFO;
  TOBJECT_INFO = record
    ID: Int64;
    Frame: Integer;
    FrameTotal: Integer;
    Time: Double;
    TimeTotal: Double;
    Width, Height: Integer;
    SampleIndex: Int64;
    SampleTotal: Int64;
    SampleNum: Integer;
    ChannelNum: Integer;
    EffectID: Int64;
    Flag: Integer;
    Layer: Integer;
    Index: Integer;
    Num: Integer;
    FrameS: Integer;
    FrameE: Integer;
    // Added 2026/8/2 (2.1.3). Read only after the InitializePlugin version gate.
    EffectLayer: Integer;
    OriginFrame: Integer;
    Handle: OBJECT_HANDLE;
    EffectHandle: EFFECT_HANDLE;
  end;

  PEDIT_INFO = ^TEDIT_INFO;
  TEDIT_INFO = record
    Width,Height,Rate,Scale,SampleRate,Frame,Layer,FrameMax,LayerMax,
      DisplayFrameStart,DisplayLayerStart,DisplayFrameNum,DisplayLayerNum,
      SelectRangeStart,SelectRangeEnd: Integer;
    GridBpmTempo: Single;
    GridBpmBeat: Integer;
    GridBpmOffset: Single;
    SceneID: Integer;
    Background: Cardinal;
  end;

  TPIXEL_RGBA = packed record
    R, G, B, A: Byte;
  end;
  PPIXEL_RGBA = ^TPIXEL_RGBA;
  TRGBAPixels = TArray<TPIXEL_RGBA>;

  TFILTER_PROC_VIDEO_GET_TEX2D = function: Pointer; cdecl;
  POBJECT_IMAGE_PARAM = ^TOBJECT_IMAGE_PARAM;
  TOBJECT_IMAGE_PARAM = record
    X, Y, Z, RX, RY, RZ, SX, SY, SZ, CX, CY, CZ, Alpha: Single;
  end;
  PFILTER_PROC_VIDEO = ^TFILTER_PROC_VIDEO;
  TFILTER_PROC_VIDEO = record
    Scene: PSCENE_INFO;
    Object_: POBJECT_INFO;
    GetImageData: procedure(Buffer: PPIXEL_RGBA); cdecl;
    SetImageData: procedure(Buffer: PPIXEL_RGBA; Width, Height: Integer); cdecl;
    GetImageTexture2D: TFILTER_PROC_VIDEO_GET_TEX2D;
    GetFramebufferTexture2D: TFILTER_PROC_VIDEO_GET_TEX2D;
    // SDK 2026/10/10: userdataまでの全ポインタを同じ順序で保持する。
    Edit: PEDIT_SECTION;
    Param: POBJECT_IMAGE_PARAM;
    GetOutputImageParam, GetImageObject: Pointer;
    DrawImage: function(Name: LPCWSTR; X, Y, Z, RX, RY, RZ, SX, SY, SZ,
      Alpha: Single): Boolean; cdecl;
    DrawPoly,
      SetDefaultAnchor, SetBlendMode, SetMaterialShine, SetSamplerMode,
      SetCullingState, SetBillboardMode, CreateImageResource,
      GetImageResourceTexture2D, CopyImageResource, ClearImageResource,
      DrawImageToResource, DrawPolyToResource, ExecPixelshaderFile,
      ExecComputeshaderFile: Pointer;
    GetBlendState: function(Mode: Integer): Pointer; cdecl;
    GetSamplerState: Pointer;
    ExecPixelshaderData: function(Code: Pointer; CodeSize: Integer;
      Target: LPCWSTR; Resources: Pointer; ResourceCount: Integer;
      Constants: Pointer; ConstantSize: Integer; Blend, Sampler: Pointer): Boolean; cdecl;
    ExecComputeshaderData, GetImageResourceSize, GetImageResourceData: Pointer;
    SetImageResourceData: function(Name: LPCWSTR; Buffer: Pointer;
      Width, Height, Pitch, Format: Integer): Boolean; cdecl;
    DeprecatedGetFont,
      SetFilterItemDataSize: Pointer;
    UserData: Pointer;
    ReleaseImageResource: function(Name: LPCWSTR): Boolean; cdecl;
    ExecEffect, SetBlendModeForce,
      GetGroupControlObject, GetGroupMatrix: Pointer;
  end;

  TFuncProcVideo = function(Video: PFILTER_PROC_VIDEO): Byte; cdecl;
  TFuncProcAudio = function(Audio: Pointer): Byte; cdecl;
  TFuncCreate = function(EffectID: Int64): Pointer; cdecl;
  TFuncDestroy = procedure(EffectID: Int64; UserData: Pointer); cdecl;

  // AviUtl2が1行のUnicode文字列を保持する文字列項目。
  PFILTER_ITEM_STRING = ^TFILTER_ITEM_STRING;
  TFILTER_ITEM_STRING = record
    ItemType: LPCWSTR; // SDK項目種別の固定値 `string`。
    Name    : LPCWSTR; // GUI表示名兼、設定取得時の項目識別名。
    Value   : LPCWSTR; // AviUtl2が管理する現在の文字列。
  end;

  // SDK v2.1.17の複数行テキスト。Valueはエスケープ前のUnicode文字列。
  PFILTER_ITEM_TEXT = ^TFILTER_ITEM_TEXT;
  TFILTER_ITEM_TEXT = record
    ItemType: LPCWSTR; // SDK項目種別の固定値 `text`。
    Name    : LPCWSTR; // GUI表示名兼、設定取得時の項目識別名。
    Value   : LPCWSTR; // ホスト所有。フィルタ処理の呼出し内で複製する。
  end;

  // AviUtl2が現在値と範囲を管理する数値トラック項目。
  PFILTER_ITEM_TRACK = ^TFILTER_ITEM_TRACK;
  TFILTER_ITEM_TRACK = record
    ItemType : LPCWSTR; // SDK項目種別の固定値 `track`。
    Name     : LPCWSTR; // GUI表示名兼、設定取得時の項目識別名。
    Value    : Double;  // 初期値。配置後はAviUtl2が現在値を保持する。
    S        : Double;  // 最小値。
    E        : Double;  // 最大値。
    Step     : Double;  // GUI上の変更単位。
  end;

  // オン／オフを保持するチェックボックス項目。
  PFILTER_ITEM_CHECK = ^TFILTER_ITEM_CHECK;
  TFILTER_ITEM_CHECK = record
    ItemType: LPCWSTR; // SDK項目種別の固定値 `check`。
    Name    : LPCWSTR; // GUI表示名兼、設定取得時の項目識別名。
    Value   : Byte;    // 0=False、1=True。
  end;

  // 後続の設定項目を折りたたむグループ見出し。
  PFILTER_ITEM_GROUP = ^TFILTER_ITEM_GROUP;
  TFILTER_ITEM_GROUP = record
    ItemType: LPCWSTR;       // SDK項目種別の固定値 `group`。
    Name: LPCWSTR;
    DefaultVisible: Byte;
  end;

  // 列挙値から1つを選ぶ選択項目。ListはName=nilの要素で終端する。
  PFILTER_ITEM_SELECT = ^TFILTER_ITEM_SELECT;
  TFILTER_ITEM_SELECT_ITEM = record
    Name : LPCWSTR; // GUIに表示する選択肢名。
    Value: Integer; // プラグイン内部の識別値。編集APIへ設定するときはNameをUTF-8で渡す。
  end;
  TFILTER_ITEM_SELECT = record
    ItemType: LPCWSTR;                   // SDK項目種別の固定値 `select`。
    Name    : LPCWSTR;                   // GUI表示名兼、設定取得時の項目識別名。
    Value   : Integer;                   // 現在選択されている識別値。
    List    : ^TFILTER_ITEM_SELECT_ITEM; // nil終端された選択肢配列。
  end;

  // AviUtl2 v2.1.16で条件名nilを指定すると、対象項目を常に隠す。
  TFILTER_ITEM_DATA = record
    ItemType, Name: LPCWSTR;
    Value: Pointer;
    Size: Integer;
  end;

  TFILTER_ITEM_HIDE_RULE = record
    ItemType: LPCWSTR;
    Name: LPCWSTR;
    ConditionName: LPCWSTR;
    ConditionOperator: Integer;
    ConditionValue: Integer;
  end;

  // 選択中オブジェクトへ設定を反映する編集コールバック付きボタン。
  PFILTER_ITEM_BUTTON = ^TFILTER_ITEM_BUTTON;
  TFILTER_ITEM_BUTTON = record
    ItemType: LPCWSTR;
    Name: LPCWSTR;
    Callback: TFilterItemButtonCallback;
    Callback2: TFilterItemButtonCallback2; // 対象オブジェクトとエフェクトを指定できるSDK形式。
  end;

  // SDK配置はB,G,R,X。Xは予約領域であり、描画アルファには使用しない。
  PFILTER_ITEM_COLOR = ^TFILTER_ITEM_COLOR;
  TFILTER_ITEM_COLOR = record
    ItemType: LPCWSTR; // SDK項目種別の固定値 `color`。
    Name: LPCWSTR;     // GUI表示名兼、設定取得時の項目識別名。
    B, G, R, X: Byte;  // 青、緑、赤、予約領域。
  end;

  // AviUtl2が選択したファイルパスをValueへ保持するファイル選択項目。
  PFILTER_ITEM_FILE = ^TFILTER_ITEM_FILE;
  TFILTER_ITEM_FILE = record
    ItemType   : LPCWSTR; // SDK項目種別の固定値 `file`。
    Name       : LPCWSTR; // GUI表示名兼、設定取得時の項目識別名。
    Value      : LPCWSTR; // AviUtl2が管理する現在のファイルパス。
    FileFilter : LPCWSTR; // ファイル選択ダイアログ用の二重nil終端フィルター。
  end;

  PFILTER_PLUGIN_TABLE = ^TFILTER_PLUGIN_TABLE;
  TFILTER_PLUGIN_TABLE = record
    Flag: Integer;
    Name: LPCWSTR;
    Label_: LPCWSTR;
    Information: LPCWSTR;
    Items: ^Pointer;
    Func_Proc_Video: TFuncProcVideo;
    Func_Proc_Audio: TFuncProcAudio;
    Func_Create: TFuncCreate;
    Func_Destroy: TFuncDestroy;
  end;

  TEditSectionParamCallback = procedure(Param: Pointer; Edit: PEDIT_SECTION); cdecl;
  TSceneVideoCallback = procedure(Param: Pointer; Frame: Integer; Buffer: Pointer;
    Width, Height, Pitch: Integer); cdecl;
  PEDIT_HANDLE = ^TEDIT_HANDLE;
  TEDIT_HANDLE = record
    CallEditSection: Pointer;
    CallEditSectionParam: function(Param: Pointer; Callback: TEditSectionParamCallback):
      Boolean; cdecl;
    GetEditInfo: procedure(Info: PEDIT_INFO; Size: Integer); cdecl;
    RestartHostApp, EnumEffectName, EnumModuleInfo: Pointer;
    GetHostAppWindow: function: NativeUInt; cdecl;
    GetEditState: function: Integer; cdecl;
    CallReadSection, CallReadSectionParam, EnumEffectItem: Pointer;
    RenderingSceneVideo: function(Frame: Integer; Param: Pointer;
      Callback: TSceneVideoCallback): Boolean; cdecl;
    RenderingSceneAudio: Pointer;
    WaitRenderingTask: procedure; cdecl;
    EnumFontNameThroughCreateProject: array[14..22] of Pointer;
    OpenProjectFile: function(FileName: LPCWSTR; ShowConfirm: Boolean): Boolean; cdecl;
    SaveProjectFile: function(FileName: LPCWSTR): Boolean; cdecl;
    OutputFile, GetHighDpiRatio: Pointer;
    GetDirect3DDevice: function: Pointer; cdecl;
  end;

  PHOST_APP_TABLE = ^THOST_APP_TABLE;
  THOST_APP_TABLE = record
    SetPluginInformation: procedure(Information: LPCWSTR); cdecl;
    RegisterInputPlugin, RegisterOutputPlugin: Pointer;
    RegisterFilterPlugin: procedure(Table: PFILTER_PLUGIN_TABLE); cdecl;
    RegisterScriptModule, RegisterImportMenu, RegisterExportMenu,
      RegisterWindowClient: Pointer;
    CreateEditHandle: function: PEDIT_HANDLE; cdecl;
  end;

const
  OBJECT_FLAG_FILTER_OBJECT = 1;
  FILTER_FLAG_VIDEO = 1;
  FILTER_FLAG_INPUT = 4; // 公式SDK: メディアオブジェクトの初期画像を生成する。
  FILTER_FLAG_FILTER = 8;
  FILTER_FLAG_USERDATA = 16;

implementation

end.
