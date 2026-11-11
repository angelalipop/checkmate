import 'package:test/test.dart';
import '../server/lib/my_subjects/grading_calculator.dart';

void main(){
 Map<String,dynamic> a(int id,String type,{String period='prelims',bool eligible=true})=>{'id':id,'assessment_type':type,'grading_period':period,'grade_eligible':eligible};
 Map<String,dynamic> c(int id,num? score,{num max=10,String status='completed'})=>{'exam_id':id,'score':score,'max_score':max,'status':status};
 Map<String,num> weights()=>Map<String,num>.of(GradingCalculator.defaults);
 test('all three quizzes share one category; PT and LAB share another',(){
  for(final t in ['quiz','short_quiz','long_quiz']){expect(GradingCalculator.category(t),'quiz');}
  for(final t in ['performance_task','laboratory']){expect(GradingCalculator.category(t),'pt');}
  expect(GradingCalculator.category('other'),isNull);expect(GradingCalculator.category(null),isNull);
 });
 test('major examination periods and aliases are explicit',(){
  expect(GradingCalculator.validatePeriod(null,'prelim'),'prelims');expect(GradingCalculator.majorPeriod('prefinal'),'pre_finals');expect(GradingCalculator.majorPeriod('finals'),'finals');
  expect(()=>GradingCalculator.validatePeriod('midterm','prelim'),throwsArgumentError);
 });
 test('invalid periods are rejected',(){expect(()=>GradingCalculator.validatePeriod('winter','quiz'),throwsArgumentError);});
 test('preferences require two distributions of 100',(){final w=weights()..['quiz']=21;expect(()=>GradingCalculator.validatePreferences(w),throwsArgumentError);});
 test('weights reject NaN, negatives, excess precision, missing keys',(){for(final value in [double.nan,-1,10.001]){final w=weights()..['pt']=value;expect(()=>GradingCalculator.validatePreferences(w),throwsArgumentError);}expect(()=>GradingCalculator.validatePreferences({}),throwsArgumentError);});
 test('decimal weights total exactly in hundredths',(){final w=weights()..['pt']=33.33..['quiz']=33.33..['exam']=33.34;expect(GradingCalculator.validatePreferences(w)['pt'],33.33);});
 test('assessment percentages are equally weighted despite unequal maximums',(){
  final g=GradingCalculator.student([a(1,'short_quiz'),a(2,'long_quiz'),a(3,'performance_task'),a(4,'prelim')],[c(1,5),c(2,40,max:40),c(3,10),c(4,10)],weights());
  expect(g['prelims']['categories']['quiz']['percentage'],75);expect(g['prelims']['grade'],95);
 });
 test('PT and LAB receive equal shares within their combined category',(){
  final g=GradingCalculator.student([a(1,'performance_task'),a(2,'performance_task'),a(3,'laboratory'),a(4,'quiz'),a(5,'prelim')],[c(1,10),c(2,5),c(3,0,max:100),c(4,10),c(5,10)],weights());
  expect(g['prelims']['categories']['pt']['percentage'],50);expect(g['prelims']['grade'],85);
 });
 test('recorded zero is complete and distinct from missing',(){
  final as=[a(1,'quiz'),a(2,'performance_task'),a(3,'prelim')];
  final zero=GradingCalculator.student(as,[c(1,0),c(2,10),c(3,10)],weights());expect(zero['prelims']['grade'],80);
  final missing=GradingCalculator.student(as,[c(1,null),c(2,10),c(3,10)],weights());expect(missing['prelims']['grade'],isNull);
 });
 test('review, pending, absent and invalid maximum block grade',(){
  final as=[a(1,'quiz'),a(2,'performance_task'),a(3,'prelim')];
  for(final status in ['needs_review','pending','absent']){final g=GradingCalculator.student(as,[c(1,10,status:status),c(2,10),c(3,10)],weights());expect(g['prelims']['grade'],isNull);}
  final g=GradingCalculator.student(as,[c(1,0,max:0),c(2,10),c(3,10)],weights());expect(g['prelims']['grade'],isNull);
 });
 test('draft assessments appear but are excluded from calculation',(){
  final g=GradingCalculator.student([a(1,'quiz'),a(2,'performance_task'),a(3,'prelim'),a(4,'quiz',eligible:false)],[c(1,10),c(2,10),c(3,10)],weights());expect(g['prelims']['grade'],100);
 });
 test('no assessment in positive category produces INC',(){final g=GradingCalculator.student([a(1,'quiz')],[c(1,10)],weights());expect(g['prelims']['grade'],isNull);});
 test('zero weighted categories and periods do not require scores',(){final w=weights()..['pt']=0..['quiz']=100..['exam']=0..['prelims']=100..['midterm']=0..['pre_finals']=0..['finals']=0;final g=GradingCalculator.student([a(1,'quiz')],[c(1,5)],w);expect(g['final_grade'],50);});
 test('all four periods contribute saved weights; interim is unnormalized',(){
  final as=<Map<String,dynamic>>[],cs=<Map<String,dynamic>>[];int id=0;
  for(final p in GradingCalculator.periods){for(final t in ['quiz','performance_task','prelim']){id++;as.add(a(id,t,period:p));cs.add(c(id,p=='finals'?5:10));}}
  final g=GradingCalculator.student(as,cs,weights());expect(g['final_grade'],80);expect(g['status'],'Recorded');
  cs.removeLast();final partial=GradingCalculator.student(as,cs,weights());expect(partial['final_grade'],isNull);expect(partial['interim_contribution'],60);expect(partial['completed_period_weight'],60);
 });
 test('unclassified historical record prevents final grade without guessing',(){final w=weights()..['pt']=0..['quiz']=100..['exam']=0..['prelims']=100..['midterm']=0..['pre_finals']=0..['finals']=0;final g=GradingCalculator.student([a(1,'quiz'),{'id':2,'assessment_type':null,'grading_period':null,'grade_eligible':true}],[c(1,10)],w);expect(g['final_grade'],isNull);expect(g['requires_classification'],isTrue);});
}
