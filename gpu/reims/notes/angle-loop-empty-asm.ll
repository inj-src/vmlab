; ModuleID = '/vmlab/tmp/hit.bc'
target datalayout = "e-p:64:64:64-i1:8:8-i8:8:8-i16:16:16-i32:32:32-i64:64:64-f32:32:32-f64:64:64-v16:16:16-v24:32:32-v32:32:32-v48:64:64-v64:64:64-v96:128:128-v128:128:128-v192:256:256-v256:256:256-v512:512:512-v1024:1024:1024-n8:16:32"
target triple = "air64-apple-macosx15.0.0"

%struct.ANGLE_UserUniforms = type { <4 x float>, <3 x float>, <4 x float>, <2 x float>, [8 x i8] }
%struct.ANGLEUniformBlock = type { <2 x i32>, <2 x float>, i32, i32, i32, i32, <4 x i32>, i32, i32, <2 x i32> }

@llvm.global_ctors = appending global [0 x { i32, ptr, ptr }] zeroinitializer

; Function Attrs: convergent mustprogress nounwind
define <{ <4 x float> }> @main0(<4 x float> %ANGLE_vertexIn.0, <4 x float> %ANGLE_vertexIn.1, <2 x float> %ANGLE_vertexIn.2, ptr addrspace(2) nocapture noundef readonly align 16 dereferenceable(64) "air-buffer-no-alias" %ANGLE_userUniforms, ptr addrspace(2) nocapture noundef readonly align 16 dereferenceable(64) "air-buffer-no-alias" %ANGLE_angleUniforms, i32 noundef %ANGLE_instanceIdMod, i32 noundef %ANGLE_baseInstance, i32 noundef %ANGLE_vertexIDMetal) local_unnamed_addr #0 {
entry:
  %_uutessControlArgs_S0.i = getelementptr inbounds %struct.ANGLE_UserUniforms, ptr addrspace(2) %ANGLE_userUniforms, i64 0, i32 1
  %0 = load <3 x float>, ptr addrspace(2) %_uutessControlArgs_S0.i, align 16, !alias.scope !28, !noalias !35
  %1 = extractelement <3 x float> %0, i64 0
  %2 = extractelement <3 x float> %0, i64 1
  %_uuaffineMatrix_S0.i = getelementptr inbounds %struct.ANGLE_UserUniforms, ptr addrspace(2) %ANGLE_userUniforms, i64 0, i32 2
  %3 = load <4 x float>, ptr addrspace(2) %_uuaffineMatrix_S0.i, align 16, !alias.scope !28, !noalias !35
  %4 = shufflevector <4 x float> %3, <4 x float> poison, <2 x i32> <i32 0, i32 1>
  %5 = shufflevector <4 x float> %3, <4 x float> poison, <2 x i32> <i32 2, i32 3>
  %_uutranslate_S0.i = getelementptr inbounds %struct.ANGLE_UserUniforms, ptr addrspace(2) %ANGLE_userUniforms, i64 0, i32 3
  %6 = load <2 x float>, ptr addrspace(2) %_uutranslate_S0.i, align 16, !tbaa !39, !alias.scope !28, !noalias !35
  %7 = shufflevector <4 x float> %ANGLE_vertexIn.0, <4 x float> poison, <2 x i32> <i32 0, i32 1>
  %8 = shufflevector <4 x float> %ANGLE_vertexIn.0, <4 x float> poison, <2 x i32> <i32 2, i32 3>
  %9 = shufflevector <4 x float> %ANGLE_vertexIn.1, <4 x float> poison, <2 x i32> <i32 0, i32 1>
  %10 = shufflevector <4 x float> %ANGLE_vertexIn.1, <4 x float> poison, <2 x i32> <i32 2, i32 3>
  %bc.i = bitcast <4 x float> %ANGLE_vertexIn.1 to <4 x i32>
  %astype.i.i = extractelement <4 x i32> %bc.i, i64 3
  %and.i.i = and i32 %astype.i.i, 2147483647
  %cmp.i784.i = icmp eq i32 %and.i.i, 2139095040
  %11 = extractelement <4 x float> %ANGLE_vertexIn.1, i64 2
  %spec.select.i = select i1 %cmp.i784.i, float %11, float -1.000000e+00
  %spec.select860.i = select i1 %cmp.i784.i, <2 x float> %9, <2 x float> %10
  %cmp.i = fcmp olt float %spec.select.i, 0.000000e+00
  br i1 %cmp.i, label %if.then10.i, label %if.else28.i

if.then10.i:                                      ; preds = %entry
  %cmp.i777.i = fcmp oeq <2 x float> %7, %8
  %12 = tail call i1 @air.all.v2i1(<2 x i1> %cmp.i777.i) #3
  br i1 %12, label %if.then14.i, label %if.else21.i

if.then14.i:                                      ; preds = %if.then10.i
  %cmp.i775.i = fcmp oeq <2 x float> %9, %spec.select860.i
  %13 = tail call i1 @air.all.v2i1(<2 x i1> %cmp.i775.i) #3
  br i1 %13, label %if.end36.i, label %if.else21.i

if.else21.i:                                      ; preds = %if.then14.i, %if.then10.i
  %mul.i863.i = fmul <2 x float> %8, <float 2.000000e+00, float 2.000000e+00>
  %14 = fsub <2 x float> %9, %mul.i863.i
  %add1.i.i = fadd <2 x float> %7, %14
  %splat.splat.i.i.i = shufflevector <2 x float> %add1.i.i, <2 x float> poison, <2 x i32> zeroinitializer
  %15 = tail call <2 x float> @llvm.fmuladd.v2f32(<2 x float> %4, <2 x float> %splat.splat.i.i.i, <2 x float> zeroinitializer) #4
  %splat.splat.i37.i.i = shufflevector <2 x float> %add1.i.i, <2 x float> undef, <2 x i32> <i32 1, i32 1>
  %16 = tail call <2 x float> @llvm.fmuladd.v2f32(<2 x float> %5, <2 x float> %splat.splat.i37.i.i, <2 x float> %15) #4
  %mul2.i.i = fmul <2 x float> %9, <float 2.000000e+00, float 2.000000e+00>
  %17 = fsub <2 x float> %spec.select860.i, %mul2.i.i
  %add4.i.i = fadd <2 x float> %8, %17
  %splat.splat.i29.i.i = shufflevector <2 x float> %add4.i.i, <2 x float> poison, <2 x i32> zeroinitializer
  %18 = tail call <2 x float> @llvm.fmuladd.v2f32(<2 x float> %4, <2 x float> %splat.splat.i29.i.i, <2 x float> zeroinitializer) #4
  %splat.splat.i33.i.i = shufflevector <2 x float> %add4.i.i, <2 x float> undef, <2 x i32> <i32 1, i32 1>
  %19 = tail call <2 x float> @llvm.fmuladd.v2f32(<2 x float> %5, <2 x float> %splat.splat.i33.i.i, <2 x float> %18) #4
  %20 = tail call float @air.dot.v2f32(<2 x float> %16, <2 x float> %16) #3
  %21 = tail call float @air.dot.v2f32(<2 x float> %19, <2 x float> %19) #3
  %22 = tail call float @air.fmax.f32(float %20, float %21) #3
  %23 = tail call float @air.sqrt.f32(float %22) #3
  %mul.i = fmul float %23, 3.000000e+00
  %24 = tail call float @air.sqrt.f32(float %mul.i) #3
  %25 = tail call float @air.ceil.f32(float %24) #3
  %26 = tail call float @air.fmax.f32(float %25, float 1.000000e+00) #3
  br label %if.end36.i

if.else28.i:                                      ; preds = %entry
  %splat.splat.i796.i = shufflevector <4 x float> %ANGLE_vertexIn.0, <4 x float> undef, <2 x i32> zeroinitializer
  %27 = tail call <2 x float> @llvm.fmuladd.v2f32(<2 x float> %4, <2 x float> %splat.splat.i796.i, <2 x float> zeroinitializer) #4
  %splat.splat.i828.i = shufflevector <4 x float> %ANGLE_vertexIn.0, <4 x float> undef, <2 x i32> <i32 1, i32 1>
  %28 = tail call <2 x float> @llvm.fmuladd.v2f32(<2 x float> %5, <2 x float> %splat.splat.i828.i, <2 x float> %27) #4
  %splat.splat.i801.i = shufflevector <4 x float> %ANGLE_vertexIn.0, <4 x float> undef, <2 x i32> <i32 2, i32 2>
  %29 = tail call <2 x float> @llvm.fmuladd.v2f32(<2 x float> %4, <2 x float> %splat.splat.i801.i, <2 x float> zeroinitializer) #4
  %splat.splat.i824.i = shufflevector <4 x float> %ANGLE_vertexIn.0, <4 x float> undef, <2 x i32> <i32 3, i32 3>
  %30 = tail call <2 x float> @llvm.fmuladd.v2f32(<2 x float> %5, <2 x float> %splat.splat.i824.i, <2 x float> %29) #4
  %splat.splat.i806.i = shufflevector <4 x float> %ANGLE_vertexIn.1, <4 x float> undef, <2 x i32> zeroinitializer
  %31 = tail call <2 x float> @llvm.fmuladd.v2f32(<2 x float> %4, <2 x float> %splat.splat.i806.i, <2 x float> zeroinitializer) #4
  %splat.splat.i820.i = shufflevector <4 x float> %ANGLE_vertexIn.1, <4 x float> undef, <2 x i32> <i32 1, i32 1>
  %32 = tail call <2 x float> @llvm.fmuladd.v2f32(<2 x float> %5, <2 x float> %splat.splat.i820.i, <2 x float> %31) #4
  %33 = tail call <2 x float> @air.fmin.v2f32(<2 x float> %28, <2 x float> %30) #3
  %34 = tail call <2 x float> @air.fmin.v2f32(<2 x float> %33, <2 x float> %32) #3
  %35 = tail call <2 x float> @air.fmax.v2f32(<2 x float> %28, <2 x float> %30) #3
  %36 = tail call <2 x float> @air.fmax.v2f32(<2 x float> %35, <2 x float> %32) #3
  %add.i1.i = fadd <2 x float> %34, %36
  %mul.i2.i = fmul <2 x float> %add.i1.i, <float 5.000000e-01, float 5.000000e-01>
  %sub.i3.i = fsub <2 x float> %28, %mul.i2.i
  %sub4.i.i = fsub <2 x float> %30, %mul.i2.i
  %sub5.i.i = fsub <2 x float> %32, %mul.i2.i
  %mul12.i.i = fmul float %spec.select.i, -2.000000e+00
  %vecinit.i.i4.i = insertelement <2 x float> undef, float %mul12.i.i, i64 0
  %vecinit1.i.i5.i = shufflevector <2 x float> %vecinit.i.i4.i, <2 x float> poison, <2 x i32> zeroinitializer
  %mul14.i.i = fmul <2 x float> %vecinit1.i.i5.i, %sub4.i.i
  %add15.i.i = fadd <2 x float> %sub.i3.i, %mul14.i.i
  %add16.i.i = fadd <2 x float> %sub5.i.i, %add15.i.i
  %37 = tail call float @air.dot.v2f32(<2 x float> %add16.i.i, <2 x float> %add16.i.i) #3
  %astype.i.i.i.i = bitcast float %37 to i32
  %and.i.i.i.i = and i32 %astype.i.i.i.i, 2147483647
  %cmp.i.i.i.i = icmp eq i32 %and.i.i.i.i, 2139095040
  br i1 %cmp.i.i.i.i, label %if.then.i.i.i, label %if.end.i.i.i

if.then.i.i.i:                                    ; preds = %if.else28.i
  %mul.i.i6.i = fmul <2 x float> %add16.i.i, <float 0x3BD0000000000000, float 0x3BD0000000000000>
  %38 = tail call float @air.dot.v2f32(<2 x float> %mul.i.i6.i, <2 x float> %mul.i.i6.i) #3
  %39 = tail call float @air.sqrt.f32(float %38) #3
  %mul4.i.i.i = fmul float %39, 0x4410000000000000
  br label %_Z34_uwangs_formula_conic_p2_fff2f2f2ffDv2_fS_S_f.exit.i

if.end.i.i.i:                                     ; preds = %if.else28.i
  %cmp.i.i7.i = fcmp olt float %37, 0x3980000000000000
  br i1 %cmp.i.i7.i, label %if.then7.i.i.i, label %if.end12.i.i.i

if.then7.i.i.i:                                   ; preds = %if.end.i.i.i
  %mul8.i.i.i = fmul <2 x float> %add16.i.i, <float 0x43F0000000000000, float 0x43F0000000000000>
  %40 = tail call float @air.dot.v2f32(<2 x float> %mul8.i.i.i, <2 x float> %mul8.i.i.i) #3
  %41 = tail call float @air.sqrt.f32(float %40) #3
  %mul11.i.i.i = fmul float %41, 0x3BF0000000000000
  br label %_Z34_uwangs_formula_conic_p2_fff2f2f2ffDv2_fS_S_f.exit.i

if.end12.i.i.i:                                   ; preds = %if.end.i.i.i
  %42 = tail call float @air.sqrt.f32(float %37) #3
  br label %_Z34_uwangs_formula_conic_p2_fff2f2f2ffDv2_fS_S_f.exit.i

_Z34_uwangs_formula_conic_p2_fff2f2f2ffDv2_fS_S_f.exit.i: ; preds = %if.end12.i.i.i, %if.then7.i.i.i, %if.then.i.i.i
  %retval.0.i.i.i = phi float [ %mul4.i.i.i, %if.then.i.i.i ], [ %mul11.i.i.i, %if.then7.i.i.i ], [ %42, %if.end12.i.i.i ]
  %43 = tail call float @air.dot.v2f32(<2 x float> %sub.i3.i, <2 x float> %sub.i3.i) #3
  %44 = tail call float @air.dot.v2f32(<2 x float> %sub4.i.i, <2 x float> %sub4.i.i) #3
  %45 = tail call float @air.fmax.f32(float %43, float %44) #3
  %46 = tail call float @air.dot.v2f32(<2 x float> %sub5.i.i, <2 x float> %sub5.i.i) #3
  %47 = tail call float @air.fmax.f32(float %45, float %46) #3
  %48 = tail call float @air.sqrt.f32(float %47) #3
  %mul20.i.i = fmul float %48, 4.000000e+00
  %add21.i.i = fadd float %mul20.i.i, -1.000000e+00
  %49 = tail call float @air.fmax.f32(float 0.000000e+00, float %add21.i.i) #3
  %add18.i.i = fadd float %mul12.i.i, 2.000000e+00
  %50 = tail call float @air.fabs.f32(float %add18.i.i) #3
  %mul24.i.i = fmul float %retval.0.i.i.i, 4.000000e+00
  %mul25.i.i = fmul float %49, %50
  %add26.i.i = fadd float %mul24.i.i, %mul25.i.i
  %51 = tail call float @air.fmin.f32(float %spec.select.i, float 1.000000e+00) #3
  %mul28.i.i = fmul float %51, 4.000000e+00
  %div.i8.i = fdiv float %add26.i.i, %mul28.i.i
  %52 = tail call float @air.sqrt.f32(float %div.i8.i) #3
  %53 = tail call float @air.ceil.f32(float %52) #3
  %54 = tail call float @air.fmax.f32(float %53, float 1.000000e+00) #3
  br label %if.end36.i

if.end36.i:                                       ; preds = %_Z34_uwangs_formula_conic_p2_fff2f2f2ffDv2_fS_S_f.exit.i, %if.else21.i, %if.then14.i
  %_unumParametricSegments.1.i = phi float [ %54, %_Z34_uwangs_formula_conic_p2_fff2f2f2ffDv2_fS_S_f.exit.i ], [ %26, %if.else21.i ], [ 1.000000e+00, %if.then14.i ]
  %cmp.i773.i = fcmp oeq <2 x float> %7, %8
  %55 = tail call i1 @air.all.v2i1(<2 x i1> %cmp.i773.i) #3
  br i1 %55, label %if.then38.i, label %if.end44.i

if.then38.i:                                      ; preds = %if.end36.i
  %cmp.i771.i = fcmp oeq <2 x float> %8, %9
  %56 = tail call i1 @air.all.v2i1(<2 x i1> %cmp.i771.i) #3
  %spec.select860..i = select i1 %56, <2 x float> %spec.select860.i, <2 x float> %9
  br label %if.end44.i

if.end44.i:                                       ; preds = %if.then38.i, %if.end36.i
  %ANGLE_scbc.0.i = phi <2 x float> [ %spec.select860..i, %if.then38.i ], [ %8, %if.end36.i ]
  %sub.i.i = fsub <2 x float> %ANGLE_scbc.0.i, %7
  %cmp.i.i864.i = fcmp oeq <2 x float> %sub.i.i, zeroinitializer
  %57 = tail call i1 @air.all.v2i1(<2 x i1> %cmp.i.i864.i) #3
  br i1 %57, label %_Z30_urobust_normalize_diff_f2f2f2Dv2_fS_.exit.i, label %if.else.i.i

if.else.i.i:                                      ; preds = %if.end44.i
  %58 = extractelement <2 x float> %sub.i.i, i64 0
  %59 = tail call float @air.fabs.f32(float %58) #3
  %60 = extractelement <2 x float> %sub.i.i, i64 1
  %61 = tail call float @air.fabs.f32(float %60) #3
  %62 = tail call float @air.fmax.f32(float %59, float %61) #3
  %div.i.i = fdiv float 1.000000e+00, %62
  %splat.splatinsert.i865.i = insertelement <2 x float> poison, float %div.i.i, i64 0
  %splat.splat.i866.i = shufflevector <2 x float> %splat.splatinsert.i865.i, <2 x float> poison, <2 x i32> zeroinitializer
  %mul.i867.i = fmul <2 x float> %sub.i.i, %splat.splat.i866.i
  %63 = tail call float @air.dot.v2f32(<2 x float> %mul.i867.i, <2 x float> %mul.i867.i) #3
  %64 = tail call float @air.fast_rsqrt.f32(float %63) #3
  %splat.splatinsert.i.i.i = insertelement <2 x float> poison, float %64, i64 0
  %splat.splat.i.i868.i = shufflevector <2 x float> %splat.splatinsert.i.i.i, <2 x float> poison, <2 x i32> zeroinitializer
  %mul.i.i.i = fmul <2 x float> %mul.i867.i, %splat.splat.i.i868.i
  br label %_Z30_urobust_normalize_diff_f2f2f2Dv2_fS_.exit.i

_Z30_urobust_normalize_diff_f2f2f2Dv2_fS_.exit.i: ; preds = %if.else.i.i, %if.end44.i
  %retval.0.i.i = phi <2 x float> [ %mul.i.i.i, %if.else.i.i ], [ zeroinitializer, %if.end44.i ]
  %cmp.i769.i = fcmp oeq <2 x float> %spec.select860.i, %9
  %65 = tail call i1 @air.all.v2i1(<2 x i1> %cmp.i769.i) #3
  br i1 %65, label %if.then47.i, label %if.end53.i

if.then47.i:                                      ; preds = %_Z30_urobust_normalize_diff_f2f2f2Dv2_fS_.exit.i
  %cmp.i767.i = fcmp oeq <2 x float> %9, %8
  %66 = tail call i1 @air.all.v2i1(<2 x i1> %cmp.i767.i) #3
  %..i = select i1 %66, <2 x float> %7, <2 x float> %8
  br label %if.end53.i

if.end53.i:                                       ; preds = %if.then47.i, %_Z30_urobust_normalize_diff_f2f2f2Dv2_fS_.exit.i
  %ANGLE_scc1.0.i = phi <2 x float> [ %..i, %if.then47.i ], [ %9, %_Z30_urobust_normalize_diff_f2f2f2Dv2_fS_.exit.i ]
  %sub.i869.i = fsub <2 x float> %spec.select860.i, %ANGLE_scc1.0.i
  %cmp.i.i870.i = fcmp oeq <2 x float> %sub.i869.i, zeroinitializer
  %67 = tail call i1 @air.all.v2i1(<2 x i1> %cmp.i.i870.i) #3
  br i1 %67, label %_Z30_urobust_normalize_diff_f2f2f2Dv2_fS_.exit880.i, label %if.else.i878.i

if.else.i878.i:                                   ; preds = %if.end53.i
  %68 = extractelement <2 x float> %sub.i869.i, i64 0
  %69 = tail call float @air.fabs.f32(float %68) #3
  %70 = extractelement <2 x float> %sub.i869.i, i64 1
  %71 = tail call float @air.fabs.f32(float %70) #3
  %72 = tail call float @air.fmax.f32(float %69, float %71) #3
  %div.i871.i = fdiv float 1.000000e+00, %72
  %splat.splatinsert.i872.i = insertelement <2 x float> poison, float %div.i871.i, i64 0
  %splat.splat.i873.i = shufflevector <2 x float> %splat.splatinsert.i872.i, <2 x float> poison, <2 x i32> zeroinitializer
  %mul.i874.i = fmul <2 x float> %sub.i869.i, %splat.splat.i873.i
  %73 = tail call float @air.dot.v2f32(<2 x float> %mul.i874.i, <2 x float> %mul.i874.i) #3
  %74 = tail call float @air.fast_rsqrt.f32(float %73) #3
  %splat.splatinsert.i.i875.i = insertelement <2 x float> poison, float %74, i64 0
  %splat.splat.i.i876.i = shufflevector <2 x float> %splat.splatinsert.i.i875.i, <2 x float> poison, <2 x i32> zeroinitializer
  %mul.i.i877.i = fmul <2 x float> %mul.i874.i, %splat.splat.i.i876.i
  br label %_Z30_urobust_normalize_diff_f2f2f2Dv2_fS_.exit880.i

_Z30_urobust_normalize_diff_f2f2f2Dv2_fS_.exit880.i: ; preds = %if.else.i878.i, %if.end53.i
  %retval.0.i879.i = phi <2 x float> [ %mul.i.i877.i, %if.else.i878.i ], [ zeroinitializer, %if.end53.i ]
  %cmp.i.i = fcmp oeq <2 x float> %retval.0.i.i, zeroinitializer
  %75 = tail call i1 @air.all.v2i1(<2 x i1> %cmp.i.i) #3
  %spec.select861.i = select i1 %75, <2 x float> <float -1.000000e+00, float 0.000000e+00>, <2 x float> %retval.0.i879.i
  %spec.select862.i = select i1 %75, <2 x float> <float 1.000000e+00, float 0.000000e+00>, <2 x float> %retval.0.i.i
  %shr.i = ashr i32 %ANGLE_vertexIDMetal, 1
  %76 = tail call float @air.convert.f.f32.s.i32(i32 %shr.i) #3
  %and.i = and i32 %ANGLE_vertexIDMetal, 1
  %cmp62.not.i = icmp eq i32 %and.i, 0
  %fneg.i = fneg float %76
  %_uedgeID.0.i = select i1 %cmp62.not.i, float %76, float %fneg.i
  %sub.i = fsub <2 x float> %9, %7
  %sub68.i = fsub <2 x float> %spec.select860.i, %8
  %vecext1.i.i = extractelement <2 x float> %sub.i, i64 0
  %vecext4.i.i = extractelement <2 x float> %sub68.i, i64 1
  %vecext7.i.i = extractelement <2 x float> %sub.i, i64 1
  %vecext11.i.i = extractelement <2 x float> %sub68.i, i64 0
  %77 = fneg float %vecext7.i.i
  %neg.i.i = fmul float %vecext11.i.i, %77
  %78 = tail call float @llvm.fmuladd.f32(float %vecext1.i.i, float %vecext4.i.i, float %neg.i.i) #4
  %79 = tail call float @air.fabs.f32(float %_uedgeID.0.i) #3
  %sub72.i = fadd float %79, -4.000000e+00
  %cmp73.i = fcmp olt float %sub72.i, 0.000000e+00
  br i1 %cmp73.i, label %if.then76.i, label %if.end87.i

if.then76.i:                                      ; preds = %_Z30_urobust_normalize_diff_f2f2f2Dv2_fS_.exit880.i
  %cmp.i.i.i = fcmp oeq <2 x float> %7, %ANGLE_vertexIn.2
  %80 = tail call i1 @air.all.v2i1(<2 x i1> %cmp.i.i.i) #3
  br i1 %80, label %if.end83.i, label %if.then80.i

if.then80.i:                                      ; preds = %if.then76.i
  %sub.i883.i = fsub <2 x float> %7, %ANGLE_vertexIn.2
  %cmp.i.i884.i = fcmp oeq <2 x float> %sub.i883.i, zeroinitializer
  %81 = tail call i1 @air.all.v2i1(<2 x i1> %cmp.i.i884.i) #3
  br i1 %81, label %if.end83.i, label %if.else.i892.i

if.else.i892.i:                                   ; preds = %if.then80.i
  %82 = extractelement <2 x float> %sub.i883.i, i64 0
  %83 = tail call float @air.fabs.f32(float %82) #3
  %84 = extractelement <2 x float> %sub.i883.i, i64 1
  %85 = tail call float @air.fabs.f32(float %84) #3
  %86 = tail call float @air.fmax.f32(float %83, float %85) #3
  %div.i885.i = fdiv float 1.000000e+00, %86
  %splat.splatinsert.i886.i = insertelement <2 x float> poison, float %div.i885.i, i64 0
  %splat.splat.i887.i = shufflevector <2 x float> %splat.splatinsert.i886.i, <2 x float> poison, <2 x i32> zeroinitializer
  %mul.i888.i = fmul <2 x float> %sub.i883.i, %splat.splat.i887.i
  %87 = tail call float @air.dot.v2f32(<2 x float> %mul.i888.i, <2 x float> %mul.i888.i) #3
  %88 = tail call float @air.fast_rsqrt.f32(float %87) #3
  %splat.splatinsert.i.i889.i = insertelement <2 x float> poison, float %88, i64 0
  %splat.splat.i.i890.i = shufflevector <2 x float> %splat.splatinsert.i.i889.i, <2 x float> poison, <2 x i32> zeroinitializer
  %mul.i.i891.i = fmul <2 x float> %mul.i888.i, %splat.splat.i.i890.i
  br label %if.end83.i

if.end83.i:                                       ; preds = %if.else.i892.i, %if.then80.i, %if.then76.i
  %_utan0.1.i = phi <2 x float> [ %spec.select862.i, %if.then76.i ], [ %mul.i.i891.i, %if.else.i892.i ], [ zeroinitializer, %if.then80.i ]
  %vecext1.i847.i = extractelement <2 x float> %_utan0.1.i, i64 0
  %vecext4.i851.i = extractelement <2 x float> %spec.select862.i, i64 1
  %vecext7.i854.i = extractelement <2 x float> %_utan0.1.i, i64 1
  %vecext11.i857.i = extractelement <2 x float> %spec.select862.i, i64 0
  %89 = fneg float %vecext7.i854.i
  %neg.i859.i = fmul float %vecext11.i857.i, %89
  %90 = tail call float @llvm.fmuladd.f32(float %vecext1.i847.i, float %vecext4.i851.i, float %neg.i859.i) #4
  br label %if.end87.i

if.end87.i:                                       ; preds = %if.end83.i, %_Z30_urobust_normalize_diff_f2f2f2Dv2_fS_.exit880.i
  %_uturn.0.i = phi float [ %90, %if.end83.i ], [ %78, %_Z30_urobust_normalize_diff_f2f2f2Dv2_fS_.exit880.i ]
  %_utan1.1.i = phi <2 x float> [ %spec.select862.i, %if.end83.i ], [ %spec.select861.i, %_Z30_urobust_normalize_diff_f2f2f2Dv2_fS_.exit880.i ]
  %_utan0.2.i = phi <2 x float> [ %_utan0.1.i, %if.end83.i ], [ %spec.select862.i, %_Z30_urobust_normalize_diff_f2f2f2Dv2_fS_.exit880.i ]
  %91 = tail call float @air.dot.v2f32(<2 x float> %_utan0.2.i, <2 x float> %_utan1.1.i) #3
  %92 = tail call float @air.clamp.f32(float %91, float -1.000000e+00, float 1.000000e+00) #3
  %93 = tail call float @air.acos.f32(float %92) #3
  %cmp91.i = fcmp olt float %_uturn.0.i, 0.000000e+00
  %fneg95.i = fneg float %93
  %_urotation.0.i = select i1 %cmp91.i, float %fneg95.i, float %93
  %94 = tail call float @air.sign.f32(float %_uedgeID.0.i) #3
  br i1 %cmp73.i, label %if.then102.i, label %if.else139.i

if.then102.i:                                     ; preds = %if.end87.i
  %add104.i = fadd float %sub72.i, 3.000000e+00
  %95 = tail call float @air.fabs.f32(float %_uturn.0.i) #3
  %96 = tail call float @air.dot.v2f32(<2 x float> %_utan0.2.i, <2 x float> %_utan0.2.i) #3
  %97 = tail call float @air.dot.v2f32(<2 x float> %_utan1.1.i, <2 x float> %_utan1.1.i) #3
  %mul108.i = fmul float %96, %97
  %98 = tail call float @air.rsqrt.f32(float %mul108.i) #3
  %mul110.i = fmul float %95, %98
  %cmp111.i = fcmp olt float %mul110.i, 0x3F847AE140000000
  %cmp118.i = fcmp uge float %91, 0.000000e+00
  %ANGLE__2.0.in.i = select i1 %cmp111.i, i1 %cmp118.i, i1 false
  %cmp124.i = fcmp ult float %add104.i, 0.000000e+00
  %or.cond.i = select i1 %ANGLE__2.0.in.i, i1 true, i1 %cmp124.i
  br i1 %or.cond.i, label %if.end137.i, label %if.then127.i

if.then127.i:                                     ; preds = %if.then102.i
  br i1 %cmp91.i, label %if.then129.i, label %if.else131.i

if.then129.i:                                     ; preds = %if.then127.i
  %99 = tail call float @air.fmin.f32(float %94, float 0.000000e+00) #3
  br label %if.end137.i

if.else131.i:                                     ; preds = %if.then127.i
  %100 = tail call float @air.fmax.f32(float %94, float 0.000000e+00) #3
  br label %if.end137.i

if.end137.i:                                      ; preds = %if.else131.i, %if.then129.i, %if.then102.i
  %_ustrokeOutset.1.i = phi float [ %94, %if.then102.i ], [ %99, %if.then129.i ], [ %100, %if.else131.i ]
  %101 = tail call float @air.fmax.f32(float %add104.i, float 0.000000e+00) #3
  br label %if.end150.i

if.else139.i:                                     ; preds = %if.end87.i
  %102 = tail call float @air.fabs.f32(float %_urotation.0.i) #3
  %mul143.i = fmul float %1, %102
  %103 = tail call float @air.ceil.f32(float %mul143.i) #3
  %104 = tail call float @air.fmax.f32(float %103, float 1.000000e+00) #3
  %105 = tail call float @air.fmin.f32(float %104, float 1.637800e+04) #3
  %sub147.i = fsub float 1.637800e+04, %105
  %add148.i = fadd float %sub147.i, 1.000000e+00
  %106 = tail call float @air.fmin.f32(float %_unumParametricSegments.1.i, float %add148.i) #3
  br label %if.end150.i

if.end150.i:                                      ; preds = %if.else139.i, %if.end137.i
  %_ustrokeOutset.2.i = phi float [ %_ustrokeOutset.1.i, %if.end137.i ], [ %94, %if.else139.i ]
  %_unumRadialSegments.0.i = phi float [ 2.000000e+00, %if.end137.i ], [ %105, %if.else139.i ]
  %_ucombinedEdgeID.0.i = phi float [ %101, %if.end137.i ], [ %sub72.i, %if.else139.i ]
  %_unumParametricSegments.2.i = phi float [ 1.000000e+00, %if.end137.i ], [ %106, %if.else139.i ]
  %_up3.1.i = phi <2 x float> [ %7, %if.end137.i ], [ %spec.select860.i, %if.else139.i ]
  %_up2.0.i = phi <2 x float> [ %7, %if.end137.i ], [ %9, %if.else139.i ]
  %_up1.0.i = phi <2 x float> [ %7, %if.end137.i ], [ %8, %if.else139.i ]
  %div.i = fdiv float %_urotation.0.i, %_unumRadialSegments.0.i
  %add151.i = fadd float %_unumRadialSegments.0.i, %_unumParametricSegments.2.i
  %sub152.i = fadd float %add151.i, -1.000000e+00
  %cmp153.i = fcmp ult float %_ucombinedEdgeID.0.i, %sub152.i
  %cmp155.i = fcmp ogt float %_ucombinedEdgeID.0.i, %sub152.i
  %_ustrokeOutset.3.i = select i1 %cmp155.i, float 0.000000e+00, float %_ustrokeOutset.2.i
  %cmp162.i = fcmp oeq float %79, 2.000000e+00
  br i1 %cmp162.i, label %if.then165.i, label %if.end178.i

if.then165.i:                                     ; preds = %if.end150.i
  %mul166.i = fmul float %92, 5.000000e-01
  %add167.i = fadd float %mul166.i, 5.000000e-01
  %mul168.i = fmul float %2, %add167.i
  %mul169.i = fmul float %2, %mul168.i
  %cmp170.i = fcmp ult float %mul169.i, 1.000000e+00
  br i1 %cmp170.i, label %if.else173.i, label %if.then171.i

if.then171.i:                                     ; preds = %if.then165.i
  %107 = tail call float @air.rsqrt.f32(float %add167.i) #3
  br label %if.end175.i

if.else173.i:                                     ; preds = %if.then165.i
  %108 = tail call float @air.sqrt.f32(float %add167.i) #3
  br label %if.end175.i

if.end175.i:                                      ; preds = %if.else173.i, %if.then171.i
  %ANGLE_sd08.0.i = phi float [ %107, %if.then171.i ], [ %108, %if.else173.i ]
  %mul176.i = fmul float %_ustrokeOutset.3.i, %ANGLE_sd08.0.i
  br label %if.end178.i

if.end178.i:                                      ; preds = %if.end175.i, %if.end150.i
  %_ustrokeOutset.4.i = phi float [ %mul176.i, %if.end175.i ], [ %_ustrokeOutset.3.i, %if.end150.i ]
  %cmp179.i = fcmp une float %_ucombinedEdgeID.0.i, 0.000000e+00
  %ANGLE__3.0.in.i = select i1 %cmp179.i, i1 %cmp153.i, i1 false
  br i1 %ANGLE__3.0.in.i, label %if.then189.i, label %if.else356.i

if.then189.i:                                     ; preds = %if.end178.i
  %sub190.i = fsub <2 x float> %_up1.0.i, %7
  %sub191.i = fsub <2 x float> %_up3.1.i, %7
  %cmp192.i = fcmp oge float %spec.select.i, 0.000000e+00
  br i1 %cmp192.i, label %if.then195.i, label %if.else206.i

if.then195.i:                                     ; preds = %if.then189.i
  %splat.splatinsert.i = insertelement <2 x float> poison, float %spec.select.i, i64 0
  %splat.splat.i = shufflevector <2 x float> %splat.splatinsert.i, <2 x float> poison, <2 x i32> zeroinitializer
  %mul196.i = fmul <2 x float> %splat.splat.i, %sub190.i
  %mul197.i = fmul <2 x float> %sub191.i, <float 5.000000e-01, float 5.000000e-01>
  %sub198.i = fsub <2 x float> %mul197.i, %mul196.i
  %sub199.i = fadd float %spec.select.i, -1.000000e+00
  %splat.splatinsert200.i = insertelement <2 x float> poison, float %sub199.i, i64 0
  %splat.splat201.i = shufflevector <2 x float> %splat.splatinsert200.i, <2 x float> poison, <2 x i32> zeroinitializer
  %mul202.i = fmul <2 x float> %splat.splat201.i, %sub191.i
  %mul205.i = fmul <2 x float> %splat.splat.i, %_up1.0.i
  br label %if.end211.i

if.else206.i:                                     ; preds = %if.then189.i
  %sub207.i = fsub <2 x float> %_up2.0.i, %_up1.0.i
  %sub208.i = fsub <2 x float> %sub207.i, %sub190.i
  %mul209.i = fmul <2 x float> %sub207.i, <float 3.000000e+00, float 3.000000e+00>
  %109 = fsub <2 x float> %sub191.i, %mul209.i
  br label %if.end211.i

if.end211.i:                                      ; preds = %if.else206.i, %if.then195.i
  %_uC.0.i = phi <2 x float> [ %mul196.i, %if.then195.i ], [ %sub190.i, %if.else206.i ]
  %_uB.0.i = phi <2 x float> [ %sub198.i, %if.then195.i ], [ %sub208.i, %if.else206.i ]
  %_uA.0.i = phi <2 x float> [ %mul202.i, %if.then195.i ], [ %109, %if.else206.i ]
  %_up1.1.i = phi <2 x float> [ %mul205.i, %if.then195.i ], [ %_up1.0.i, %if.else206.i ]
  %mul212.i = fmul float %_unumParametricSegments.2.i, 2.000000e+00
  %splat.splatinsert213.i = insertelement <2 x float> poison, float %mul212.i, i64 0
  %splat.splat214.i = shufflevector <2 x float> %splat.splatinsert213.i, <2 x float> poison, <2 x i32> zeroinitializer
  %mul215.i = fmul <2 x float> %splat.splat214.i, %_uB.0.i
  %mul216.i = fmul float %_unumParametricSegments.2.i, %_unumParametricSegments.2.i
  %splat.splatinsert217.i = insertelement <2 x float> poison, float %mul216.i, i64 0
  %splat.splat218.i = shufflevector <2 x float> %splat.splatinsert217.i, <2 x float> poison, <2 x i32> zeroinitializer
  %mul219.i = fmul <2 x float> %splat.splat218.i, %_uC.0.i
  %sub220.i = fadd float %_unumParametricSegments.2.i, -1.000000e+00
  %110 = tail call float @air.fmin.f32(float %sub220.i, float %_ucombinedEdgeID.0.i) #3
  %111 = tail call float @air.fabs.f32(float %div.i) #3
  %add224.i = fadd float %_ucombinedEdgeID.0.i, 1.000000e+00
  %mul226.i = fmul float %add224.i, %111
  br label %while.body.i

while.body.i:                                     ; preds = %if.end255.i, %if.end211.i
  %_ulastParametricEdgeID.0981.i = phi float [ 0.000000e+00, %if.end211.i ], [ %_ulastParametricEdgeID.2.i, %if.end255.i ]
  %_u_0_exp.0980.i = phi i32 [ 4, %if.end211.i ], [ %dec.i, %if.end255.i ]
  tail call void asm sideeffect "", ""() #5, !srcloc !42
  %112 = tail call float @air.convert.f.f32.s.i32(i32 %_u_0_exp.0980.i) #3
  %113 = tail call float @air.exp2.f32(float %112) #3
  %add231.i = fadd float %_ulastParametricEdgeID.0981.i, %113
  %cmp232.i = fcmp ugt float %add231.i, %110
  br i1 %cmp232.i, label %if.end255.i, label %if.then235.i

if.then235.i:                                     ; preds = %while.body.i
  %vecinit.i.i = insertelement <2 x float> undef, float %add231.i, i64 0
  %vecinit1.i.i = shufflevector <2 x float> %vecinit.i.i, <2 x float> poison, <2 x i32> zeroinitializer
  %mul237.i = fmul <2 x float> %_uA.0.i, %vecinit1.i.i
  %add238.i = fadd <2 x float> %mul215.i, %mul237.i
  %mul240.i = fmul <2 x float> %vecinit1.i.i, %add238.i
  %add241.i = fadd <2 x float> %mul219.i, %mul240.i
  %114 = tail call float @air.dot.v2f32(<2 x float> %add241.i, <2 x float> %add241.i) #3
  %115 = tail call float @air.fast_rsqrt.f32(float %114) #3
  %splat.splatinsert.i.i = insertelement <2 x float> poison, float %115, i64 0
  %splat.splat.i.i = shufflevector <2 x float> %splat.splatinsert.i.i, <2 x float> poison, <2 x i32> zeroinitializer
  %mul.i.i = fmul <2 x float> %add241.i, %splat.splat.i.i
  %116 = tail call float @air.dot.v2f32(<2 x float> %mul.i.i, <2 x float> %_utan0.2.i) #3
  %117 = fmul float %111, %add231.i
  %add245.i = fsub float %mul226.i, %117
  %118 = tail call float @air.fmin.f32(float %add245.i, float 0x400921FB60000000) #3
  %119 = tail call float @air.cos.f32(float %118) #3
  %cmp248.i = fcmp ult float %116, %119
  %_ulastParametricEdgeID.1.i = select i1 %cmp248.i, float %_ulastParametricEdgeID.0981.i, float %add231.i
  br label %if.end255.i

if.end255.i:                                      ; preds = %if.then235.i, %while.body.i
  %_ulastParametricEdgeID.2.i = phi float [ %_ulastParametricEdgeID.1.i, %if.then235.i ], [ %_ulastParametricEdgeID.0981.i, %while.body.i ]
  %dec.i = add nsw i32 %_u_0_exp.0980.i, -1
  %cmp256.not.i = icmp eq i32 %_u_0_exp.0980.i, 0
  br i1 %cmp256.not.i, label %while.end.i, label %while.body.i, !llvm.loop !43

while.end.i:                                      ; preds = %if.end255.i
  %div258.i = fdiv float %_ulastParametricEdgeID.2.i, %_unumParametricSegments.2.i
  %sub259.i = fsub float %_ucombinedEdgeID.0.i, %_ulastParametricEdgeID.2.i
  %120 = extractelement <2 x float> %_utan0.2.i, i64 0
  %121 = tail call float @air.clamp.f32(float %120, float -1.000000e+00, float 1.000000e+00) #3
  %122 = tail call float @air.acos.f32(float %121) #3
  %123 = extractelement <2 x float> %_utan0.2.i, i64 1
  %cmp262.i = fcmp ult float %123, 0.000000e+00
  %fneg265.i = fneg float %122
  %ANGLE_sd3b.0.i = select i1 %cmp262.i, float %fneg265.i, float %122
  %mul267.i = fmul float %div.i, %sub259.i
  %add268.i = fadd float %mul267.i, %ANGLE_sd3b.0.i
  %124 = tail call float @air.cos.f32(float %add268.i) #3
  %125 = tail call float @air.sin.f32(float %add268.i) #3
  %vecinit.i899.i = insertelement <2 x float> undef, float %124, i64 0
  %vecinit1.i900.i = insertelement <2 x float> %vecinit.i899.i, float %125, i64 1
  %fneg272.i = fneg float %125
  %vecinit.i901.i = insertelement <2 x float> undef, float %fneg272.i, i64 0
  %vecinit1.i902.i = insertelement <2 x float> %vecinit.i901.i, float %124, i64 1
  %126 = tail call float @air.dot.v2f32(<2 x float> %vecinit1.i902.i, <2 x float> %_uA.0.i) #3
  %127 = tail call float @air.dot.v2f32(<2 x float> %vecinit1.i902.i, <2 x float> %_uB.0.i) #3
  %128 = tail call float @air.dot.v2f32(<2 x float> %vecinit1.i902.i, <2 x float> %_uC.0.i) #3
  %mul277.i = fmul float %127, %127
  %mul278.i = fmul float %126, %128
  %sub279.i = fsub float %mul277.i, %mul278.i
  %129 = tail call float @air.fmax.f32(float %sub279.i, float 0.000000e+00) #3
  %130 = tail call float @air.sqrt.f32(float %129) #3
  %cmp282.i = fcmp ogt float %127, 0.000000e+00
  %fneg286.i = fneg float %130
  %_uq.0.i = select i1 %cmp282.i, float %fneg286.i, float %130
  %sub289.i = fsub float %_uq.0.i, %127
  %mul290.i = fmul float %sub289.i, -5.000000e-01
  %mul291.i = fmul float %126, %mul290.i
  %mul292.i = fmul float %sub289.i, %sub289.i
  %add293.i = fadd float %mul292.i, %mul291.i
  %131 = tail call float @air.fabs.f32(float %add293.i) #3
  %add296.i = fadd float %mul278.i, %mul291.i
  %132 = tail call float @air.fabs.f32(float %add296.i) #3
  %cmp298.i = fcmp olt float %131, %132
  %vecinit.i903.i = insertelement <2 x float> undef, float %sub289.i, i64 0
  %vecinit1.i904.i = insertelement <2 x float> %vecinit.i903.i, float %126, i64 1
  %vecinit.i905.i = insertelement <2 x float> undef, float %128, i64 0
  %vecinit1.i906.i = insertelement <2 x float> %vecinit.i905.i, float %sub289.i, i64 1
  %ANGLE_sd58.0.i = select i1 %cmp298.i, <2 x float> %vecinit1.i904.i, <2 x float> %vecinit1.i906.i
  %133 = extractelement <2 x float> %ANGLE_sd58.0.i, i64 1
  %cmp304.i = fcmp une float %133, 0.000000e+00
  %134 = extractelement <2 x float> %ANGLE_sd58.0.i, i64 0
  %div306.i = fdiv float %134, %133
  %ANGLE_sd5b.0.i = select i1 %cmp304.i, float %div306.i, float 0.000000e+00
  %135 = tail call float @air.clamp.f32(float %ANGLE_sd5b.0.i, float 0.000000e+00, float 1.000000e+00) #3
  %cmp310.i = fcmp oeq float %sub259.i, 0.000000e+00
  %_uradialT.0.i = select i1 %cmp310.i, float 0.000000e+00, float %135
  %136 = tail call float @air.fmax.f32(float %div258.i, float %_uradialT.0.i) #3
  %sub.i907.i = fsub <2 x float> %_up1.1.i, %7
  %vecinit.i.i.i = insertelement <2 x float> undef, float %136, i64 0
  %vecinit1.i.i.i = shufflevector <2 x float> %vecinit.i.i.i, <2 x float> poison, <2 x i32> zeroinitializer
  %mul.i908.i = fmul <2 x float> %sub.i907.i, %vecinit1.i.i.i
  %add.i.i = fadd <2 x float> %7, %mul.i908.i
  %sub.i909.i = fsub <2 x float> %_up2.0.i, %_up1.1.i
  %mul.i912.i = fmul <2 x float> %sub.i909.i, %vecinit1.i.i.i
  %add.i913.i = fadd <2 x float> %_up1.1.i, %mul.i912.i
  %sub.i914.i = fsub <2 x float> %_up3.1.i, %_up2.0.i
  %mul.i917.i = fmul <2 x float> %sub.i914.i, %vecinit1.i.i.i
  %add.i918.i = fadd <2 x float> %_up2.0.i, %mul.i917.i
  %sub.i919.i = fsub <2 x float> %add.i913.i, %add.i.i
  %mul.i922.i = fmul <2 x float> %vecinit1.i.i.i, %sub.i919.i
  %add.i923.i = fadd <2 x float> %add.i.i, %mul.i922.i
  %sub.i924.i = fsub <2 x float> %add.i918.i, %add.i913.i
  %mul.i927.i = fmul <2 x float> %vecinit1.i.i.i, %sub.i924.i
  %add.i928.i = fadd <2 x float> %add.i913.i, %mul.i927.i
  %sub.i929.i = fsub <2 x float> %add.i928.i, %add.i923.i
  %mul.i932.i = fmul <2 x float> %vecinit1.i.i.i, %sub.i929.i
  %add.i933.i = fadd <2 x float> %add.i923.i, %mul.i932.i
  %sub323.i = fadd float %spec.select.i, -1.000000e+00
  %mul324.i = fmul float %sub323.i, %136
  %add325.i = fadd float %mul324.i, 1.000000e+00
  %add326.i = fadd float %spec.select.i, 1.000000e+00
  %sub327.i = fsub float %add326.i, %add325.i
  %sub328.i = fsub float %sub327.i, %add325.i
  %mul329.i = fmul float %136, %sub328.i
  %add330.i = fadd float %add325.i, %mul329.i
  %cmp331.i = fcmp une float %136, %_uradialT.0.i
  br i1 %cmp331.i, label %if.then334.i, label %if.end348.i

if.then334.i:                                     ; preds = %while.end.i
  br i1 %cmp192.i, label %if.then336.i, label %if.else344.i

if.then336.i:                                     ; preds = %if.then334.i
  %splat.splatinsert337.i = insertelement <2 x float> poison, float %add325.i, i64 0
  %splat.splat338.i = shufflevector <2 x float> %splat.splatinsert337.i, <2 x float> poison, <2 x i32> zeroinitializer
  %mul339.i = fmul <2 x float> %add.i913.i, %splat.splat338.i
  %splat.splatinsert340.i = insertelement <2 x float> poison, float %sub327.i, i64 0
  %splat.splat341.i = shufflevector <2 x float> %splat.splatinsert340.i, <2 x float> poison, <2 x i32> zeroinitializer
  %mul342.i = fmul <2 x float> %add.i.i, %splat.splat341.i
  %sub.i934.i = fsub <2 x float> %mul339.i, %mul342.i
  %cmp.i.i935.i = fcmp oeq <2 x float> %sub.i934.i, zeroinitializer
  %137 = tail call i1 @air.all.v2i1(<2 x i1> %cmp.i.i935.i) #3
  br i1 %137, label %if.end348.i, label %if.else.i943.i

if.else.i943.i:                                   ; preds = %if.then336.i
  %138 = extractelement <2 x float> %sub.i934.i, i64 0
  %139 = tail call float @air.fabs.f32(float %138) #3
  %140 = extractelement <2 x float> %sub.i934.i, i64 1
  %141 = tail call float @air.fabs.f32(float %140) #3
  %142 = tail call float @air.fmax.f32(float %139, float %141) #3
  %div.i936.i = fdiv float 1.000000e+00, %142
  %splat.splatinsert.i937.i = insertelement <2 x float> poison, float %div.i936.i, i64 0
  %splat.splat.i938.i = shufflevector <2 x float> %splat.splatinsert.i937.i, <2 x float> poison, <2 x i32> zeroinitializer
  %mul.i939.i = fmul <2 x float> %sub.i934.i, %splat.splat.i938.i
  %143 = tail call float @air.dot.v2f32(<2 x float> %mul.i939.i, <2 x float> %mul.i939.i) #3
  %144 = tail call float @air.fast_rsqrt.f32(float %143) #3
  %splat.splatinsert.i.i940.i = insertelement <2 x float> poison, float %144, i64 0
  %splat.splat.i.i941.i = shufflevector <2 x float> %splat.splatinsert.i.i940.i, <2 x float> poison, <2 x i32> zeroinitializer
  %mul.i.i942.i = fmul <2 x float> %mul.i939.i, %splat.splat.i.i941.i
  br label %if.end348.i

if.else344.i:                                     ; preds = %if.then334.i
  %cmp.i.i947.i = fcmp oeq <2 x float> %sub.i929.i, zeroinitializer
  %145 = tail call i1 @air.all.v2i1(<2 x i1> %cmp.i.i947.i) #3
  br i1 %145, label %if.end348.i, label %if.else.i955.i

if.else.i955.i:                                   ; preds = %if.else344.i
  %146 = extractelement <2 x float> %sub.i929.i, i64 0
  %147 = tail call float @air.fabs.f32(float %146) #3
  %148 = extractelement <2 x float> %sub.i929.i, i64 1
  %149 = tail call float @air.fabs.f32(float %148) #3
  %150 = tail call float @air.fmax.f32(float %147, float %149) #3
  %div.i948.i = fdiv float 1.000000e+00, %150
  %splat.splatinsert.i949.i = insertelement <2 x float> poison, float %div.i948.i, i64 0
  %splat.splat.i950.i = shufflevector <2 x float> %splat.splatinsert.i949.i, <2 x float> poison, <2 x i32> zeroinitializer
  %mul.i951.i = fmul <2 x float> %sub.i929.i, %splat.splat.i950.i
  %151 = tail call float @air.dot.v2f32(<2 x float> %mul.i951.i, <2 x float> %mul.i951.i) #3
  %152 = tail call float @air.fast_rsqrt.f32(float %151) #3
  %splat.splatinsert.i.i952.i = insertelement <2 x float> poison, float %152, i64 0
  %splat.splat.i.i953.i = shufflevector <2 x float> %splat.splatinsert.i.i952.i, <2 x float> poison, <2 x i32> zeroinitializer
  %mul.i.i954.i = fmul <2 x float> %mul.i951.i, %splat.splat.i.i953.i
  br label %if.end348.i

if.end348.i:                                      ; preds = %if.else.i955.i, %if.else344.i, %if.else.i943.i, %if.then336.i, %while.end.i
  %_utangent.0.i = phi <2 x float> [ %vecinit1.i900.i, %while.end.i ], [ %mul.i.i942.i, %if.else.i943.i ], [ zeroinitializer, %if.then336.i ], [ %mul.i.i954.i, %if.else.i955.i ], [ zeroinitializer, %if.else344.i ]
  br i1 %cmp192.i, label %if.then350.i, label %_Z13ANGLE__0_mainR29ANGLE_InvocationVertexGlobalsR15ANGLE_VertexOutR14ANGLE_VertexInRU11MTLconstantK18ANGLE_UserUniforms.exit

if.then350.i:                                     ; preds = %if.end348.i
  %splat.splatinsert351.i = insertelement <2 x float> poison, float %add330.i, i64 0
  %splat.splat352.i = shufflevector <2 x float> %splat.splatinsert351.i, <2 x float> poison, <2 x i32> zeroinitializer
  %div353.i = fdiv <2 x float> %add.i923.i, %splat.splat352.i
  br label %_Z13ANGLE__0_mainR29ANGLE_InvocationVertexGlobalsR15ANGLE_VertexOutR14ANGLE_VertexInRU11MTLconstantK18ANGLE_UserUniforms.exit

if.else356.i:                                     ; preds = %if.end178.i
  %cmp357.i = fcmp oeq float %_ucombinedEdgeID.0.i, 0.000000e+00
  %_utan0.2._utan1.1.i = select i1 %cmp357.i, <2 x float> %_utan0.2.i, <2 x float> %_utan1.1.i
  %ANGLE_sd7a.0.i = select i1 %cmp357.i, <2 x float> %7, <2 x float> %_up3.1.i
  br label %_Z13ANGLE__0_mainR29ANGLE_InvocationVertexGlobalsR15ANGLE_VertexOutR14ANGLE_VertexInRU11MTLconstantK18ANGLE_UserUniforms.exit

_Z13ANGLE__0_mainR29ANGLE_InvocationVertexGlobalsR15ANGLE_VertexOutR14ANGLE_VertexInRU11MTLconstantK18ANGLE_UserUniforms.exit: ; preds = %if.else356.i, %if.then350.i, %if.end348.i
  %_ustrokeCoord.0.i = phi <2 x float> [ %ANGLE_sd7a.0.i, %if.else356.i ], [ %div353.i, %if.then350.i ], [ %add.i933.i, %if.end348.i ]
  %_utangent.1.i = phi <2 x float> [ %_utan0.2._utan1.1.i, %if.else356.i ], [ %_utangent.0.i, %if.then350.i ], [ %_utangent.0.i, %if.end348.i ]
  %153 = extractelement <3 x float> %0, i64 2
  %154 = extractelement <2 x float> %_utangent.1.i, i64 0
  %fneg366.i = fneg float %154
  %155 = extractelement <2 x float> %_utangent.1.i, i64 1
  %vecinit.i958.i = insertelement <2 x float> undef, float %155, i64 0
  %vecinit1.i959.i = insertelement <2 x float> %vecinit.i958.i, float %fneg366.i, i64 1
  %mul368.i = fmul float %153, %_ustrokeOutset.4.i
  %splat.splatinsert369.i = insertelement <2 x float> poison, float %mul368.i, i64 0
  %splat.splat370.i = shufflevector <2 x float> %splat.splatinsert369.i, <2 x float> poison, <2 x i32> zeroinitializer
  %mul371.i = fmul <2 x float> %splat.splat370.i, %vecinit1.i959.i
  %add372.i = fadd <2 x float> %_ustrokeCoord.0.i, %mul371.i
  %splat.splat.i811.i = shufflevector <2 x float> %add372.i, <2 x float> poison, <2 x i32> zeroinitializer
  %156 = tail call <2 x float> @llvm.fmuladd.v2f32(<2 x float> %4, <2 x float> %splat.splat.i811.i, <2 x float> zeroinitializer) #4
  %splat.splat.i816.i = shufflevector <2 x float> %add372.i, <2 x float> undef, <2 x i32> <i32 1, i32 1>
  %157 = tail call <2 x float> @llvm.fmuladd.v2f32(<2 x float> %5, <2 x float> %splat.splat.i816.i, <2 x float> %156) #4
  %add374.i = fadd <2 x float> %6, %157
  %_usk_RTAdjust.i = getelementptr inbounds %struct.ANGLE_UserUniforms, ptr addrspace(2) %ANGLE_userUniforms, i64 0, i32 0
  %158 = load <4 x float>, ptr addrspace(2) %_usk_RTAdjust.i, align 16, !alias.scope !28, !noalias !35
  %159 = shufflevector <4 x float> %158, <4 x float> poison, <2 x i32> <i32 0, i32 2>
  %mul377.i = fmul <2 x float> %159, %add374.i
  %160 = shufflevector <4 x float> %158, <4 x float> poison, <2 x i32> <i32 1, i32 3>
  %add381.i = fadd <2 x float> %160, %mul377.i
  %161 = shufflevector <2 x float> %add381.i, <2 x float> poison, <4 x i32> <i32 0, i32 1, i32 poison, i32 poison>
  %vecinit3.i965.i2 = insertelement <4 x float> %161, float 1.000000e+00, i64 3
  %ANGLE_depthRange = getelementptr inbounds %struct.ANGLEUniformBlock, ptr addrspace(2) %ANGLE_angleUniforms, i64 0, i32 1
  %162 = load <2 x float>, ptr addrspace(2) %ANGLE_depthRange, align 8, !alias.scope !35, !noalias !28
  %163 = extractelement <2 x float> %162, i64 1
  %164 = extractelement <2 x float> %162, i64 0
  %cmp = fcmp olt float %163, %164
  %165 = select i1 %cmp, float -0.000000e+00, float 0.000000e+00
  %166 = insertelement <4 x float> %vecinit3.i965.i2, float %165, i64 2
  %ANGLE_misc = getelementptr inbounds %struct.ANGLEUniformBlock, ptr addrspace(2) %ANGLE_angleUniforms, i64 0, i32 5
  %167 = load i32, ptr addrspace(2) %ANGLE_misc, align 4, !tbaa !45, !alias.scope !35, !noalias !28
  %168 = and i32 %167, 1048576
  %tobool.not = icmp eq i32 %168, 0
  %add = fadd float %165, 1.000000e+00
  %mul7 = fmul float %add, 5.000000e-01
  %169 = insertelement <4 x float> %166, float %mul7, i64 2
  %170 = select i1 %tobool.not, <4 x float> %166, <4 x float> %169
  %ANGLE_flipXY = getelementptr inbounds %struct.ANGLEUniformBlock, ptr addrspace(2) %ANGLE_angleUniforms, i64 0, i32 3
  %171 = load i32, ptr addrspace(2) %ANGLE_flipXY, align 4, !tbaa !48, !alias.scope !35, !noalias !28
  %172 = tail call <4 x float> @air.unpack.snorm4x8.v4f32(i32 %171) #3
  %173 = extractelement <4 x float> %170, i64 1
  %174 = extractelement <4 x float> %172, i64 3
  %mul12 = fmul float %174, %173
  %175 = insertelement <4 x float> %170, float %mul12, i64 1
  %176 = insertvalue <{ <4 x float> }> undef, <4 x float> %175, 0
  ret <{ <4 x float> }> %176
}

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare i1 @air.all.v2i1(<2 x i1>) local_unnamed_addr #1

; Function Attrs: nocallback nofree nosync nounwind speculatable willreturn memory(none)
declare <2 x float> @llvm.fmuladd.v2f32(<2 x float>, <2 x float>, <2 x float>) #2

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare float @air.dot.v2f32(<2 x float>, <2 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare float @air.fmax.f32(float, float) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare float @air.sqrt.f32(float) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare float @air.ceil.f32(float) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <2 x float> @air.fmin.v2f32(<2 x float>, <2 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <2 x float> @air.fmax.v2f32(<2 x float>, <2 x float>) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare float @air.fabs.f32(float) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare float @air.fmin.f32(float, float) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare float @air.fast_rsqrt.f32(float) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare float @air.convert.f.f32.s.i32(i32) local_unnamed_addr #1

; Function Attrs: nocallback nofree nosync nounwind speculatable willreturn memory(none)
declare float @llvm.fmuladd.f32(float, float, float) #2

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare float @air.clamp.f32(float, float, float) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare float @air.acos.f32(float) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare float @air.sign.f32(float) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare float @air.rsqrt.f32(float) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare float @air.exp2.f32(float) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare float @air.cos.f32(float) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare float @air.sin.f32(float) local_unnamed_addr #1

; Function Attrs: mustprogress nofree nosync nounwind willreturn memory(none)
declare <4 x float> @air.unpack.snorm4x8.v4f32(i32) local_unnamed_addr #1

attributes #0 = { convergent mustprogress nounwind "frame-pointer"="all" "min-legal-vector-width"="128" "no-builtins" "no-trapping-math"="true" "stack-protector-buffer-size"="8" }
attributes #1 = { mustprogress nofree nosync nounwind willreturn memory(none) }
attributes #2 = { nocallback nofree nosync nounwind speculatable willreturn memory(none) }
attributes #3 = { nounwind willreturn memory(none) }
attributes #4 = { nounwind }
attributes #5 = { convergent nounwind }

!llvm.module.flags = !{!0, !1, !2, !3, !4, !5, !6, !7}
!air.version = !{!8}
!llvm.ident = !{!9}
!air.language_version = !{!10}
!air.compile_options = !{!11, !12, !13}
!air.vertex = !{!14}

!0 = !{i32 7, !"air.max_device_buffers", i32 31}
!1 = !{i32 7, !"air.max_constant_buffers", i32 31}
!2 = !{i32 7, !"air.max_threadgroup_buffers", i32 31}
!3 = !{i32 7, !"air.max_textures", i32 128}
!4 = !{i32 7, !"air.max_read_write_textures", i32 8}
!5 = !{i32 7, !"air.max_samplers", i32 16}
!6 = !{i32 1, !"wchar_size", i32 4}
!7 = !{i32 7, !"frame-pointer", i32 2}
!8 = !{i32 2, i32 7, i32 0}
!9 = !{!"Apple metal version 32023.886 (metalfe-32023.886.1)"}
!10 = !{!"Metal", i32 3, i32 2, i32 0}
!11 = !{!"air.compile.denorms_disable"}
!12 = !{!"air.compile.fast_math_disable"}
!13 = !{!"air.compile.framebuffer_fetch_enable"}
!14 = !{ptr @main0, !15, !17}
!15 = !{!16}
!16 = !{!"air.position", !"air.arg_type_name", !"float4", !"air.arg_name", !"gl_Position"}
!17 = !{!18, !19, !20, !21, !23, !25, !26, !27}
!18 = !{i32 0, !"air.vertex_input", !"air.location_index", i32 0, i32 1, !"air.arg_type_name", !"float4", !"air.arg_name", !"_upts01Attr"}
!19 = !{i32 1, !"air.vertex_input", !"air.location_index", i32 1, i32 1, !"air.arg_type_name", !"float4", !"air.arg_name", !"_upts23Attr"}
!20 = !{i32 2, !"air.vertex_input", !"air.location_index", i32 2, i32 1, !"air.arg_type_name", !"float2", !"air.arg_name", !"_uargsAttr"}
!21 = !{i32 3, !"air.buffer", !"air.buffer_size", i32 64, !"air.location_index", i32 19, i32 1, !"air.read", !"air.address_space", i32 2, !"air.struct_type_info", !22, !"air.arg_type_size", i32 64, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"ANGLE_UserUniforms", !"air.arg_name", !"ANGLE_userUniforms"}
!22 = !{i32 0, i32 16, i32 0, !"float4", !"_usk_RTAdjust", i32 16, i32 16, i32 0, !"float3", !"_uutessControlArgs_S0", i32 32, i32 16, i32 0, !"float4", !"_uuaffineMatrix_S0", i32 48, i32 8, i32 0, !"float2", !"_uutranslate_S0"}
!23 = !{i32 4, !"air.buffer", !"air.buffer_size", i32 64, !"air.location_index", i32 17, i32 1, !"air.read", !"air.address_space", i32 2, !"air.struct_type_info", !24, !"air.arg_type_size", i32 64, !"air.arg_type_align_size", i32 16, !"air.arg_type_name", !"ANGLEUniformBlock", !"air.arg_name", !"ANGLE_angleUniforms"}
!24 = !{i32 0, i32 8, i32 0, !"uint2", !"ANGLE_acbBufferOffsets", i32 8, i32 8, i32 0, !"float2", !"ANGLE_depthRange", i32 16, i32 4, i32 0, !"uint", !"ANGLE_renderArea", i32 20, i32 4, i32 0, !"uint", !"ANGLE_flipXY", i32 24, i32 4, i32 0, !"uint", !"ANGLE_dither", i32 28, i32 4, i32 0, !"uint", !"ANGLE_misc", i32 32, i32 16, i32 0, !"int4", !"ANGLE_xfbBufferOffsets", i32 48, i32 4, i32 0, !"int", !"ANGLE_xfbVerticesPerInstance", i32 52, i32 4, i32 0, !"uint", !"ANGLE_coverageMask", i32 56, i32 8, i32 0, !"uint2", !"ANGLE_unused"}
!25 = !{i32 5, !"air.instance_id", !"air.arg_type_name", !"uint", !"air.arg_name", !"ANGLE_instanceIdMod", !"air.arg_unused"}
!26 = !{i32 6, !"air.base_instance", !"air.arg_type_name", !"uint", !"air.arg_name", !"ANGLE_baseInstance", !"air.arg_unused"}
!27 = !{i32 7, !"air.vertex_id", !"air.arg_type_name", !"uint", !"air.arg_name", !"ANGLE_vertexIDMetal"}
!28 = !{!29, !31, !33}
!29 = distinct !{!29, !30, !"air-alias-scope-arg(3)"}
!30 = distinct !{!30, !"air-alias-scopes(main0)"}
!31 = distinct !{!31, !32, !"air-alias-scope-arg(3)"}
!32 = distinct !{!32, !"air-alias-scopes-loader(main0)"}
!33 = distinct !{!33, !34, !"air-alias-scope-arg(3)"}
!34 = distinct !{!34, !"air-alias-scopes-device-lowering(main0)"}
!35 = !{!36, !37, !38}
!36 = distinct !{!36, !30, !"air-alias-scope-arg(4)"}
!37 = distinct !{!37, !32, !"air-alias-scope-arg(4)"}
!38 = distinct !{!38, !34, !"air-alias-scope-arg(4)"}
!39 = !{!40, !40, i64 0}
!40 = !{!"omnipotent char", !41, i64 0}
!41 = !{!"Simple C++ TBAA"}
!42 = !{i64 17398}
!43 = distinct !{!43, !44}
!44 = !{!"llvm.loop.mustprogress"}
!45 = !{!46, !47, i64 28}
!46 = !{!"_ZTS17ANGLEUniformBlock", !40, i64 0, !40, i64 8, !47, i64 16, !47, i64 20, !47, i64 24, !47, i64 28, !40, i64 32, !47, i64 48, !47, i64 52, !40, i64 56}
!47 = !{!"int", !40, i64 0}
!48 = !{!46, !47, i64 20}
