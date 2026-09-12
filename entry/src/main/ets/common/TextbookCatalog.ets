/**
 * 教材目录 RAG 索引（内置 2026 人教版课标教材目录种子数据）。
 * 以"科目 + 年级 + 册次"为键，索引每册课程的课题列表，供 Agent：
 *   - 自动定位下一节要教的课题（配合 TeachingProfile 的"上一课推进"）；
 *   - 在用户只给模糊需求（如"下周的物理课"）时自动带出具体课题。
 * 结构说明：gradeA/gradeB 以年级（7-9）为键，value 为按教学顺序排列的课题数组。
 */
export class TextbookCatalog {
  /** 科目 → 各年级 → 上册/下册 课题列表。物理仅八、九年级开设（与我检索到的人教版物理教材目录一致）。 */
  private static readonly catalog: Map<string, Map<string, Map<string, string[]>>> = new Map<
    string, Map<string, Map<string, string[]>>
    >();

  /** 内置种子数据（2026 人教版）：科目名（中文）→ 册次。 */
  private static readonly SEED: Record<string, Record<string, Record<string, string[]>>> = {
    '物理': {
      '8': {
        'A': ['长度和时间的测量', '运动的描述', '运动的快慢', '测量平均速度',
          '声音的产生与传播', '声音的特性', '声的利用', '噪声的危害和控制',
          '温度', '熔化和凝固', '汽化和液化', '升华和凝华',
          '光的直线传播', '光的反射', '平面镜成像', '光的折射', '光的色散',
          '透镜', '生活中的透镜', '凸透镜成像的规律', '眼睛和眼镜',
          '质量', '密度', '测量物质的密度'],
        'B': ['力', '弹力', '重力', '牛顿第一定律', '二力平衡', '摩擦力',
          '压强', '液体的压强', '大气压强', '流体压强与流速的关系',
          '浮力', '阿基米德原理', '物体的浮沉条件及应用',
          '功', '功率', '动能和势能', '机械能及其转化',
          '杠杆', '滑轮', '机械效率']
      },
      '9': {
        'A': ['分子热运动', '内能', '比热容', '热机', '热机的效率', '能量的转化和守恒',
          '两种电荷', '电流和电路', '串联和并联',
          '电压', '串、并联电路中电压的规律',
          '电阻', '变阻器', '欧姆定律', '电阻的测量', '欧姆定律在串并联电路中的应用',
          '电能 电功', '电功率', '测量小灯泡的电功率', '焦耳定律',
          '家庭电路', '家庭电路中电流过大的原因', '安全用电'],
        'B': ['磁现象 磁场', '电生磁', '电磁铁 电磁继电器', '电动机', '磁生电',
          '电磁波的海洋', '广播、电视和移动通信', '太阳能', '核能', '能源与可持续发展']
      }
    },
    '数学': {
      '7': {
        'A': ['有理数', '有理数的加减法', '有理数的乘除法', '有理数的乘方',
          '整式', '整式的加减', '一元一次方程', '解一元一次方程（一）合并同类项与移项',
          '解一元一次方程（二）去括号与去分母', '实际问题与一元一次方程',
          '几何图形', '直线、射线、线段', '角', '余角和补角'],
        'B': ['相交线', '垂线', '平行线', '平行线的判定与性质',
          '平面直角坐标系', '坐标方法的简单应用',
          '三角形的高、中线与角平分线', '与三角形有关的角', '全等三角形', '三角形全等的判定',
          '轴对称', '画轴对称图形', '等腰三角形', '等边三角形']
      },
      '8': {
        'A': ['全等三角形', '三角形全等的判定', '角的平分线的性质',
          '轴对称', '画轴对称图形', '等腰三角形',
          '平方根', '立方根', '实数',
          '变量与函数', '一次函数', '用函数观点看方程（组）与不等式'],
        'B': ['二次根式', '二次根式的乘除', '二次根式的加减',
          '勾股定理', '勾股定理的逆定理',
          '平行四边形', '特殊的平行四边形',
          '函数的图象', '一次函数与方程、不等式', '课题学习 选择方案']
      },
      '9': {
        'A': ['一元二次方程', '解一元二次方程', '实际问题与一元二次方程',
          '二次函数的图像和性质', '二次函数与一元二次方程', '实际问题与二次函数',
          '图形的旋转', '中心对称',
          '圆', '点和圆、直线和圆的位置关系', '正多边形和圆', '弧长和扇形面积'],
        'B': ['图形的相似', '相似三角形判定与性质', '位似',
          '锐角三角函数', '解直角三角形及其应用',
          '投影', '三视图', '直方图', '概率与统计的应用']
      }
    }
  };

  private static inited: boolean = false;

  private static ensureInit(): void {
    if (TextbookCatalog.inited) {
      return;
    }
    TextbookCatalog.inited = true;
    const subs: string[] = Object.keys(TextbookCatalog.SEED);
    for (let i: number = 0; i < subs.length; i++) {
      const sub: string = subs[i];
      if (!TextbookCatalog.catalog.has(sub)) {
        TextbookCatalog.catalog.set(sub, new Map<string, Map<string, string[]>>());
      }
      const gradeMap: Record<string, Record<string, string[]>> = TextbookCatalog.SEED[sub];
      const gKeys: string[] = Object.keys(gradeMap);
      for (let g = 0; g < gKeys.length; g++) {
        const grade: string = gKeys[g];
        const halfMap: Record<string, string[]> = gradeMap[grade];
        const inner: Map<string, string[]> = new Map<string, string[]>();
        const hKeys: string[] = Object.keys(halfMap);
        for (let h = 0; h < hKeys.length; h++) {
          inner.set(hKeys[h], halfMap[hKeys[h]]);
        }
        TextbookCatalog.catalog.get(sub)!.set(grade, inner);
      }
    }
  }

  /** 取某科目某年级某册的课题列表（空数组=该教本未内置目录）。 */
  static lessonsOf(subject: string, grade: number, half: string): string[] {
    TextbookCatalog.ensureInit();
    const g: Map<string, Map<string, string[]>> | undefined = TextbookCatalog.catalog.get(subject.trim());
    if (g === undefined) {
      return [];
    }
    const inner: Map<string, string[]> | undefined = g.get(grade.toString());
    if (inner === undefined) {
      return [];
    }
    const list: string[] | undefined = inner.get(half === 'B' ? 'B' : 'A');
    return list !== undefined ? list.slice() : [];
  }

  /** 支持的科目清单（中文名）。 */
  static subjects(): string[] {
    TextbookCatalog.ensureInit();
    const out: string[] = [];
    TextbookCatalog.catalog.forEach((_v: Map<string, Map<string, string[]>>, k: string): void => {
      out.push(k);
    });
    return out;
  }
}