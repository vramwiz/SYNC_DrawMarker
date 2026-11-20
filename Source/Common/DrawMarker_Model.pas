unit DrawMarker_Model;

interface

uses System.Types;

const
  MarkerSchema = 1;
  MaxMarkerStrokes = 512;
  MaxStrokePoints = 20000;
  MaxMarkerPoints = 80000;
  MaxMarkerJSON = 8 * 1024 * 1024;

type
  TPenKind = (pkNormal, pkMarker, pkGlow, pkDash, pkBrush);
  TInputKind = (ikMouse, ikPen);
  TAnchorKind = (akSmooth, akCorner);

const
  PenNames: array[TPenKind] of string = ('通常ペン', 'マーカー', '発光ペン', '破線ペン', '筆ペン');

type
  TStrokeStyle = record
    Kind: TPenKind;
    RGB: Cardinal;
    Width: Single;
    Opacity: Integer;
  end;

  TPenSample = record
    Position: TPointF;
    Milliseconds: Integer;
    Pressure: Single;
  end;

  TCurveAnchor = record
    Position, InHandle, OutHandle: TPointF; // ハンドルは頂点からの相対座標
    Kind: TAnchorKind;
  end;

  TMarkerStroke = record
    Style: TStrokeStyle;
    Input: TInputKind;
    Samples: TArray<TPenSample>;
    Anchors: TArray<TCurveAnchor>;
  end;

  TMarkerDocument = record
    Width, Height: Integer;
    Strokes: TArray<TMarkerStroke>;
  end;

function DefaultStyle(Kind: TPenKind): TStrokeStyle;
function ReadDocument(const Text: string; Width, Height: Integer): TMarkerDocument;
function WriteDocument(const Doc: TMarkerDocument): string;
function PointCount(const Doc: TMarkerDocument): Integer;

implementation

uses System.SysUtils, System.Math, System.JSON, System.Generics.Collections;

function DefaultStyle(Kind: TPenKind): TStrokeStyle;
const
  Colors: array[TPenKind] of Cardinal = ($FF454F, $FFDF38, $39DAFF, $FF6745, $F34C70);
  Widths: array[TPenKind] of Single = (8, 26, 8, 7, 15);
  Alphas: array[TPenKind] of Integer = (100, 42, 100, 100, 100);
begin
  Result.Kind := Kind;
  Result.RGB := Colors[Kind];
  Result.Width := Widths[Kind];
  Result.Opacity := Alphas[Kind];
end;

function PointCount(const Doc: TMarkerDocument): Integer;
var Stroke: TMarkerStroke;
begin
  Result := 0;
  for Stroke in Doc.Strokes do
    Inc(Result, Length(Stroke.Anchors) + Length(Stroke.Samples));
end;

function RequiredArray(Value: TJSONValue): TJSONArray;
begin
  if not (Value is TJSONArray) then
    raise EConvertError.Create('描画データの配列形式が正しくありません。');
  Result := TJSONArray(Value);
end;

function Number(Value: TJSONValue; MinValue, MaxValue: Double): Double;
begin
  if not (Value is TJSONNumber) or
    not TryStrToFloat(Value.Value, Result, TFormatSettings.Invariant) or
    IsNan(Result) or IsInfinite(Result) or (Result < MinValue) or (Result > MaxValue) then
    raise EConvertError.Create('描画データの数値が範囲外です。');
end;

function IntegerValue(Value: TJSONValue; MinValue, MaxValue: Integer): Integer;
var N: Double;
begin
  N := Number(Value, MinValue, MaxValue);
  Result := Trunc(N);
  if Result <> N then raise EConvertError.Create('描画データの整数が正しくありません。');
end;

function ReadPoint(Row: TJSONArray; Start: Integer): TPointF;
begin
  Result := PointF(Number(Row.Items[Start], -262144, 262144),
    Number(Row.Items[Start + 1], -262144, 262144));
end;

function ReadDocument(const Text: string; Width, Height: Integer): TMarkerDocument;
var
  JSON: TJSONValue;
  Root, Entry: TJSONObject;
  Strokes, Points, Row: TJSONArray;
  I, J, Total, PreviousTime: Integer;
  Stroke: ^TMarkerStroke;
begin
  Result := Default(TMarkerDocument);
  Result.Width := Width;
  Result.Height := Height;
  if Text = '' then Exit;
  if Length(Text) > MaxMarkerJSON then raise EConvertError.Create('描画データが大きすぎます。');
  JSON := TJSONObject.ParseJSONValue(Text);
  try
    if not (JSON is TJSONObject) then raise EConvertError.Create('描画 JSON を読み込めません。');
    Root := TJSONObject(JSON);
    if IntegerValue(Root.GetValue('version'), 1, MaxInt) <> MarkerSchema then
      raise EConvertError.Create('対応していない描画データのバージョンです。');
    Result.Width := IntegerValue(Root.GetValue('width'), 1, 16384);
    Result.Height := IntegerValue(Root.GetValue('height'), 1, 16384);
    Strokes := RequiredArray(Root.GetValue('strokes'));
    if Strokes.Count > MaxMarkerStrokes then raise EConvertError.Create('一画の数が上限を超えています。');
    SetLength(Result.Strokes, Strokes.Count);
    Total := 0;
    for I := 0 to Strokes.Count - 1 do
    begin
      if not (Strokes.Items[I] is TJSONObject) then raise EConvertError.Create('一画の形式が正しくありません。');
      Entry := TJSONObject(Strokes.Items[I]);
      Stroke := @Result.Strokes[I];
      Stroke^.Input := TInputKind(IntegerValue(Entry.GetValue('input'), 0, Ord(High(TInputKind))));
      Stroke^.Style.Kind := TPenKind(IntegerValue(Entry.GetValue('pen'), 0, Ord(High(TPenKind))));
      Stroke^.Style.RGB := IntegerValue(Entry.GetValue('rgb'), 0, $FFFFFF);
      Stroke^.Style.Width := Number(Entry.GetValue('width'), 1, 512);
      Stroke^.Style.Opacity := IntegerValue(Entry.GetValue('opacity'), 0, 100);
      Points := RequiredArray(Entry.GetValue('points'));
      Inc(Total, Points.Count);
      if (Points.Count = 0) or (Points.Count > MaxStrokePoints) or (Total > MaxMarkerPoints) then
        raise EConvertError.Create('一画の点数が範囲外です。');
      if Stroke^.Input = ikPen then SetLength(Stroke^.Samples, Points.Count)
      else SetLength(Stroke^.Anchors, Points.Count);
      PreviousTime := 0;
      for J := 0 to Points.Count - 1 do
      begin
        Row := RequiredArray(Points.Items[J]);
        if Stroke^.Input = ikPen then
        begin
          if Row.Count <> 4 then raise EConvertError.Create('ペンのサンプルが正しくありません。');
          Stroke^.Samples[J].Position := ReadPoint(Row, 0);
          Stroke^.Samples[J].Milliseconds := IntegerValue(Row.Items[2], PreviousTime, 86400000);
          Stroke^.Samples[J].Pressure := Number(Row.Items[3], 0, 1);
          PreviousTime := Stroke^.Samples[J].Milliseconds;
        end
        else
        begin
          if Row.Count <> 7 then raise EConvertError.Create('ベジェ頂点が正しくありません。');
          Stroke^.Anchors[J].Position := ReadPoint(Row, 0);
          Stroke^.Anchors[J].InHandle := ReadPoint(Row, 2);
          Stroke^.Anchors[J].OutHandle := ReadPoint(Row, 4);
          Stroke^.Anchors[J].Kind := TAnchorKind(IntegerValue(Row.Items[6], 0, Ord(High(TAnchorKind))));
        end;
      end;
    end;
  finally
    JSON.Free;
  end;
end;

function WriteDocument(const Doc: TMarkerDocument): string;
var
  Builder: TStringBuilder;
  Fmt: TFormatSettings;
  Stroke: TMarkerStroke;
  I, J: Integer;
  procedure XY(const P: TPointF);
  begin
    Builder.Append(FloatToStr(P.X, Fmt)).Append(',').Append(FloatToStr(P.Y, Fmt));
  end;
begin
  Fmt := TFormatSettings.Invariant;
  Builder := TStringBuilder.Create;
  try
    Builder.Append('{"version":').Append(MarkerSchema).Append(',"width":').Append(Doc.Width)
      .Append(',"height":').Append(Doc.Height).Append(',"strokes":[');
    for I := 0 to High(Doc.Strokes) do
    begin
      if I > 0 then Builder.Append(',');
      Stroke := Doc.Strokes[I];
      // 旧版の互換用に、サンプル形式の筆圧フラグを出力する。
      Builder.Append('{"input":').Append(Ord(Stroke.Input)).Append(',"pen":').Append(Ord(Stroke.Style.Kind))
        .Append(',"rgb":').Append(Integer(Stroke.Style.RGB)).Append(',"width":')
        .Append(FloatToStr(Stroke.Style.Width, Fmt)).Append(',"opacity":').Append(Stroke.Style.Opacity)
        .Append(',"pressure":').Append(Ord(Stroke.Input = ikPen)).Append(',"points":[');
      if Stroke.Input = ikPen then
        for J := 0 to High(Stroke.Samples) do
        begin
          if J > 0 then Builder.Append(',');
          Builder.Append('[');
          XY(Stroke.Samples[J].Position);
          Builder.Append(',').Append(Stroke.Samples[J].Milliseconds).Append(',')
            .Append(FloatToStr(Stroke.Samples[J].Pressure, Fmt)).Append(']');
        end
      else
        for J := 0 to High(Stroke.Anchors) do
        begin
          if J > 0 then Builder.Append(',');
          Builder.Append('[');
          XY(Stroke.Anchors[J].Position);
          Builder.Append(',');
          XY(Stroke.Anchors[J].InHandle);
          Builder.Append(',');
          XY(Stroke.Anchors[J].OutHandle);
          Builder.Append(',').Append(Ord(Stroke.Anchors[J].Kind)).Append(']');
        end;
      Builder.Append(']}');
    end;
    Builder.Append(']}');
    if Builder.Length > MaxMarkerJSON then raise EConvertError.Create('描画データが大きすぎます。');
    Result := Builder.ToString;
  finally
    Builder.Free;
  end;
end;

end.
