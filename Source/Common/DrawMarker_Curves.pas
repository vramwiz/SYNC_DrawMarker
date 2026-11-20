unit DrawMarker_Curves;

interface

uses System.Types, DrawMarker_Model;

type
  TPathPoint = record
    Position: TPointF;
    Time, Distance: Double;
    Pressure, Parameter: Single;
    Segment: Integer;
  end;

  TMarkerPath = record
    Style: TStrokeStyle;
    Points: TArray<TPathPoint>;
    Start, Duration: Double;
  end;

  TMarkerPaths = TArray<TMarkerPath>;

procedure SetAutomaticHandles(var Anchors: TArray<TCurveAnchor>; Index: Integer);
procedure SetAnchorKind(var Anchors: TArray<TCurveAnchor>; Index: Integer; Kind: TAnchorKind);
procedure MoveHandle(var Anchor: TCurveAnchor; Incoming: Boolean; const Position: TPointF);
procedure SplitCurve(var Anchors: TArray<TCurveAnchor>; Segment: Integer; Parameter: Single);
function BuildPath(const Stroke: TMarkerStroke; CanvasWidth: Integer): TMarkerPath;
function BuildPaths(const Doc: TMarkerDocument): TMarkerPaths;
function HitPath(const Path: TMarkerPath; const P: TPointF; ScaleX, ScaleY: Single;
  var Limit: Single; out Segment: Integer; out Parameter: Single): Boolean;
function Magnitude(const P: TPointF): Single;

implementation

uses System.Math, System.SysUtils, System.Generics.Collections;

type
  TCubic = record
    P0, P1, P2, P3: TPointF;
  end;

function Magnitude(const P: TPointF): Single;
begin
  Result := Sqrt(Sqr(P.X) + Sqr(P.Y));
end;

function UnitVector(const P: TPointF): TPointF;
var L: Single;
begin
  L := Magnitude(P);
  if L > 1E-5 then Result := P / L else Result := PointF(0, 0);
end;

procedure SetAutomaticHandles(var Anchors: TArray<TCurveAnchor>; Index: Integer);
var InVector, OutVector, Direction: TPointF;
begin
  InVector := PointF(0, 0);
  OutVector := PointF(0, 0);
  if Index > 0 then InVector := Anchors[Index].Position - Anchors[Index - 1].Position;
  if Index < High(Anchors) then OutVector := Anchors[Index + 1].Position - Anchors[Index].Position;
  if Anchors[Index].Kind = akCorner then
  begin
    Anchors[Index].InHandle := InVector * (-1 / 3);
    Anchors[Index].OutHandle := OutVector / 3;
    Exit;
  end;
  Direction := UnitVector(UnitVector(InVector) + UnitVector(OutVector));
  Anchors[Index].InHandle := Direction * (-Magnitude(InVector) / 3);
  Anchors[Index].OutHandle := Direction * (Magnitude(OutVector) / 3);
end;

procedure SetAnchorKind(var Anchors: TArray<TCurveAnchor>; Index: Integer; Kind: TAnchorKind);
begin
  Anchors[Index].Kind := Kind;
  SetAutomaticHandles(Anchors, Index);
end;

procedure MoveHandle(var Anchor: TCurveAnchor; Incoming: Boolean; const Position: TPointF);
var Offset, Opposite: TPointF;
begin
  Offset := Position - Anchor.Position;
  if Incoming then Opposite := Anchor.OutHandle else Opposite := Anchor.InHandle;
  if (Anchor.Kind = akSmooth) and (Magnitude(Offset) > 1E-5) then
    Opposite := UnitVector(Offset) * (-Magnitude(Opposite));
  if Incoming then
  begin
    Anchor.InHandle := Offset;
    Anchor.OutHandle := Opposite;
  end
  else
  begin
    Anchor.OutHandle := Offset;
    Anchor.InHandle := Opposite;
  end;
end;

function Lerp(const A, B: TPointF; T: Single): TPointF;
begin
  Result := A + (B - A) * T;
end;

function Curve(const Anchors: TArray<TCurveAnchor>; Segment: Integer): TCubic;
begin
  Result.P0 := Anchors[Segment].Position;
  Result.P3 := Anchors[Segment + 1].Position;
  Result.P1 := Result.P0 + Anchors[Segment].OutHandle;
  Result.P2 := Result.P3 + Anchors[Segment + 1].InHandle;
end;

procedure Cut(const C: TCubic; T: Single; out Left, Right: TCubic);
var M: TPointF;
begin
  Left.P0 := C.P0;
  Left.P1 := Lerp(C.P0, C.P1, T);
  M := Lerp(C.P1, C.P2, T);
  Right.P2 := Lerp(C.P2, C.P3, T);
  Right.P3 := C.P3;
  Left.P2 := Lerp(Left.P1, M, T);
  Right.P1 := Lerp(M, Right.P2, T);
  Left.P3 := Lerp(Left.P2, Right.P1, T);
  Right.P0 := Left.P3;
end;

procedure SplitCurve(var Anchors: TArray<TCurveAnchor>; Segment: Integer; Parameter: Single);
var Left, Right: TCubic; I: Integer;
begin
  Cut(Curve(Anchors, Segment), Parameter, Left, Right);
  SetLength(Anchors, Length(Anchors) + 1);
  for I := High(Anchors) downto Segment + 2 do Anchors[I] := Anchors[I - 1];
  Anchors[Segment].OutHandle := Left.P1 - Left.P0;
  Anchors[Segment + 1].Position := Left.P3;
  Anchors[Segment + 1].InHandle := Left.P2 - Left.P3;
  Anchors[Segment + 1].OutHandle := Right.P1 - Right.P0;
  Anchors[Segment + 1].Kind := akSmooth;
  Anchors[Segment + 2].InHandle := Right.P2 - Right.P3;
end;

function BuildPath(const Stroke: TMarkerStroke; CanvasWidth: Integer): TMarkerPath;
var
  Points: TList<TPathPoint>;
  I: Integer;
  Distance, MouseSpeed: Double;
  Last: TPointF;

  procedure Add(const P: TPointF; Time: Double; Pressure: Single; Segment: Integer; T: Single);
  var Item: TPathPoint;
  begin
    if Points.Count >= 350000 then raise ERangeError.Create('曲線が細かすぎます。');
    if Points.Count <> 0 then Distance := Distance + Magnitude(P - Last);
    Item.Position := P;
    Item.Distance := Distance;
    Item.Time := Time;
    if Stroke.Input = ikMouse then Item.Time := Distance / MouseSpeed;
    Item.Pressure := Pressure;
    Item.Segment := Segment;
    Item.Parameter := T;
    Points.Add(Item);
    Last := P;
  end;

  procedure Flatten(const C: TCubic; Segment, Depth: Integer; T0, T1: Single);
  var Left, Right: TCubic; M: Single;
  begin
    if (Depth = 9) or
      (Max(Magnitude(C.P1 - Lerp(C.P0, C.P3, 1 / 3)),
        Magnitude(C.P2 - Lerp(C.P0, C.P3, 2 / 3))) < 0.30) then
    begin
      Add(C.P3, 0, 1, Segment, T1);
      Exit;
    end;
    Cut(C, 0.5, Left, Right);
    M := (T0 + T1) * 0.5;
    Flatten(Left, Segment, Depth + 1, T0, M);
    Flatten(Right, Segment, Depth + 1, M, T1);
  end;

begin
  Result := Default(TMarkerPath);
  Result.Style := Stroke.Style;
  Points := TList<TPathPoint>.Create;
  try
    Distance := 0;
    Last := PointF(0, 0);
    MouseSpeed := CanvasWidth * (600 / 1920);
    if Stroke.Input = ikPen then
      for I := 0 to High(Stroke.Samples) do
        Add(Stroke.Samples[I].Position, Stroke.Samples[I].Milliseconds * 0.001,
          Stroke.Samples[I].Pressure, I - 1, 1)
    else if Length(Stroke.Anchors) > 0 then
    begin
      Add(Stroke.Anchors[0].Position, 0, 1, 0, 0);
      for I := 0 to High(Stroke.Anchors) - 1 do Flatten(Curve(Stroke.Anchors, I), I, 0, 0, 1);
    end;
    Result.Points := Points.ToArray;
    if Points.Count > 0 then Result.Duration := Max(0.001, Points.Last.Time);
  finally
    Points.Free;
  end;
end;

function BuildPaths(const Doc: TMarkerDocument): TMarkerPaths;
var I: Integer; Start: Double;
begin
  SetLength(Result, Length(Doc.Strokes));
  Start := 0;
  for I := 0 to High(Result) do
  begin
    Result[I] := BuildPath(Doc.Strokes[I], Doc.Width);
    Result[I].Start := Start;
    Start := Start + Result[I].Duration;
  end;
end;

function HitPath(const Path: TMarkerPath; const P: TPointF; ScaleX, ScaleY: Single;
  var Limit: Single; out Segment: Integer; out Parameter: Single): Boolean;
var I: Integer; A, B, V, Q: TPointF; L, U, Distance, T0: Single;
begin
  Result := False;
  Segment := -1;
  Parameter := 0;
  if Length(Path.Points) = 0 then Exit;
  A := PointF((Path.Points[0].Position.X - P.X) * ScaleX,
    (Path.Points[0].Position.Y - P.Y) * ScaleY);
  Distance := Magnitude(A);
  if Distance < Limit then
  begin
    Result := True;
    Limit := Distance;
  end;
  for I := 1 to High(Path.Points) do
  begin
    B := PointF((Path.Points[I].Position.X - P.X) * ScaleX,
      (Path.Points[I].Position.Y - P.Y) * ScaleY);
    V := B - A;
    L := Sqr(V.X) + Sqr(V.Y);
    U := 0;
    if L > 0 then U := EnsureRange(-(A.X * V.X + A.Y * V.Y) / L, 0.0, 1.0);
    Q := A + V * U;
    Distance := Magnitude(Q);
    if Distance <= Limit then
    begin
      Limit := Distance;
      Result := True;
      Segment := Path.Points[I].Segment;
      T0 := 0;
      if Path.Points[I - 1].Segment = Segment then T0 := Path.Points[I - 1].Parameter;
      Parameter := T0 + U * (Path.Points[I].Parameter - T0);
    end;
    A := B;
  end;
end;

end.
